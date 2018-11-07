//
//  DriveService+Records.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 1/30/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony

import GoogleDrive

public extension DriveService
{
    func fetchAllRemoteRecords(context: NSManagedObjectContext, completionHandler: @escaping (Result<(Set<RemoteRecord>, Data)>) -> Void) -> Progress
    {
        var filesResult: Result<Set<RemoteRecord>>?
        var tokenResult: Result<Data>?
        
        let progress = Progress.discreteProgress(totalUnitCount: 2)
        
        let filesQuery = GTLRDriveQuery_FilesList.query()
        filesQuery.pageSize = 1000
        filesQuery.fields = "nextPageToken, files(\(fileQueryFields))"
        filesQuery.completionBlock = { (ticket, object, error) in
            guard error == nil else {
                filesResult = .failure(FetchError(code: .any(error!)))
                return
            }
            
            guard let list = object as? GTLRDrive_FileList, let files = list.files else {
                filesResult = .failure(FetchError(code: .invalidResponse))
                return
            }
            
            context.performAndWait {
                let records = files.compactMap { RemoteRecord(file: $0, status: .normal, context: context) }
                filesResult = .success(Set(records))
            }
            
            progress.completedUnitCount += 1
        }
        
        let changeTokenQuery = GTLRDriveQuery_ChangesGetStartPageToken.query()
        changeTokenQuery.completionBlock = { (ticket, object, error) in
            guard error == nil else {
                tokenResult = .failure(FetchError(code: .any(error!)))
                return
            }

            guard let result = object as? GTLRDrive_StartPageToken, let token = result.startPageToken else {
                tokenResult = .failure(FetchError(code: .invalidResponse))
                return
            }

            guard let data = token.data(using: .utf8) else {
                tokenResult = .failure(FetchError(code: .invalidResponse))
                return
            }

            tokenResult = .success(data)
            
            progress.completedUnitCount += 1
        }
        
        let batchQuery = GTLRBatchQuery(queries: [filesQuery, changeTokenQuery])

        let ticket = self.service.executeQuery(batchQuery) { (ticket, object, error) in
            guard let filesResult = filesResult, let tokenResult = tokenResult else { return completionHandler(.failure(FetchError(code: .unknown))) }
            
            let result: Result<(Set<RemoteRecord>, Data)>
            
            switch (filesResult, tokenResult)
            {
            case (.success(let records), .success(let token)): result = .success((records, token))
            case (.success, .failure(let error)): result = .failure(FetchError(code: .any(error)))
            case (.failure(let error), .success): result = .failure(FetchError(code: .any(error)))
            case (.failure(let error), .failure): result = .failure(FetchError(code: .any(error)))
            }
            
            // Delete inserted RemoteRecords if filesResult is success, but the overall result is failure
            if case .failure = result, case .success(let records) = filesResult
            {
                context.performAndWait {
                    records.forEach { context.delete($0) }
                }
            }
            
            context.perform {
                completionHandler(result)
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(FetchError(code: .cancelled)))
        }
        
        return progress
    }
    
    func fetchChangedRemoteRecords(changeToken: Data, context: NSManagedObjectContext, completionHandler: @escaping (Result<(Set<RemoteRecord>, Set<String>, Data)>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let pageToken = String(data: changeToken, encoding: .utf8) else {
            completionHandler(.failure(FetchError(code: .invalidChangeToken)))
            return progress
        }
        
        let query = GTLRDriveQuery_ChangesList.query(withPageToken: pageToken)
        query.fields = "nextPageToken, newStartPageToken, changes(fileId, type, removed, file(\(fileQueryFields)))"
        query.includeRemoved = true
        query.pageSize = 1000
        
        let ticket = self.service.executeQuery(query) { (ticket, object, error) in
            guard error == nil else { return completionHandler(.failure(FetchError(code: .any(error!)))) }
            
            guard let result = object as? GTLRDrive_ChangeList,
                let newPageToken = result.newStartPageToken,
                let tokenData = newPageToken.data(using: .utf8),
                let changes = result.changes
            else { return completionHandler(.failure(FetchError(code: .invalidResponse))) }
            
            context.perform {
                
                var updatedRecords = Set<RemoteRecord>()
                var deletedIDs = Set<String>()
                
                for change in changes
                {
                    guard change.type == "file" else { continue }
                    guard let identifier = change.fileId, let isDeleted = change.removed?.boolValue else { continue }
                    
                    if isDeleted
                    {
                        deletedIDs.insert(identifier)
                    }
                    else if let file = change.file, let record = RemoteRecord(file: file, status: .updated, context: context)
                    {
                        updatedRecords.insert(record)
                    }
                }
                
                progress.totalUnitCount += 1
                
                completionHandler(.success((updatedRecords, deletedIDs, tokenData)))
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(FetchError(code: .cancelled)))
        }
        
        return progress
    }
}

public extension DriveService
{
    func upload(_ record: LocalRecord, metadata: [HarmonyMetadataKey: Any], context: NSManagedObjectContext, completionHandler: @escaping (Result<RemoteRecord>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let managedRecord = record.managedRecord else {
            completionHandler(.failure(AnyError(code: .nilManagedRecord)))
            return progress
        }
        
        do
        {
            let data = try JSONEncoder().encode(record)
            
            let file = GTLRDrive_File()
            file.name = record.recordedObjectType + "-" + record.recordedObjectIdentifier
            file.mimeType = "application/json"
            file.appProperties = GTLRDrive_File_AppProperties(json: metadata)
            
            let uploadParameters = GTLRUploadParameters(data: data, mimeType: "application/json")
            uploadParameters.shouldUploadWithSingleRequest = true
            
            let query: GTLRDriveQuery
            
            if let identifier = managedRecord.remoteRecord?.identifier, managedRecord.remoteRecord?.status != .deleted
            {
                query = GTLRDriveQuery_FilesUpdate.query(withObject: file, fileId: identifier, uploadParameters: uploadParameters)
            }
            else
            {
                query = GTLRDriveQuery_FilesCreate.query(withObject: file, uploadParameters: uploadParameters)
            }
            
            query.fields = fileQueryFields
            
            let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                context.perform {
                    guard error == nil else {
                        return completionHandler(.failure(UploadError(record: managedRecord, code: .any(error!))))
                    }
                    
                    guard let file = file as? GTLRDrive_File, let remoteRecord = RemoteRecord(file: file, status: .normal, context: context) else {
                        return completionHandler(.failure(UploadError(record: managedRecord, code: .invalidResponse)))
                    }
                    
                    completionHandler(.success(remoteRecord))
                }
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(UploadError(record: managedRecord, code: .cancelled)))
            }
        }
        catch
        {
            completionHandler(.failure(UploadError(record: managedRecord, code: .any(error))))
        }
        
        return progress
    }
    
    func download(_ record: RemoteRecord, version: ManagedVersion, context: NSManagedObjectContext, completionHandler: @escaping (Result<LocalRecord>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let managedRecord = record.managedRecord else {
            completionHandler(.failure(AnyError(code: .nilManagedRecord)))
            return progress
        }
        
        let query = GTLRDriveQuery_RevisionsGet.queryForMedia(withFileId: record.identifier, revisionId: version.identifier)
        
        let ticket = self.service.executeQuery(query) { (ticket, file, error) in
            context.perform {
                guard error == nil else {
                    return completionHandler(.failure(DownloadError(record: managedRecord, code: .any(error!))))
                }
                
                guard let file = file as? GTLRDataObject else {
                    return completionHandler(.failure(DownloadError(record: managedRecord, code: .invalidResponse)))
                }
                
                do
                {
                    let decoder = JSONDecoder()
                    decoder.managedObjectContext = context
                    
                    let record = try decoder.decode(LocalRecord.self, from: file.data)
                    completionHandler(.success(record))
                }
                catch
                {
                    completionHandler(.failure(DownloadError(record: managedRecord, code: .any(error))))
                }
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(DownloadError(record: managedRecord, code: .cancelled)))
        }
        
        return progress
    }
    
    func delete(_ record: RemoteRecord, completionHandler: @escaping (Result<Void>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let managedRecord = record.managedRecord else {
            completionHandler(.failure(AnyError(code: .nilManagedRecord)))
            
            return progress
        }
        
        let query = GTLRDriveQuery_FilesDelete.query(withFileId: record.identifier)
        
        let ticket = self.service.executeQuery(query) { (ticket, file, error) in
            if let error = error
            {
                completionHandler(.failure(DeleteError(record: managedRecord, code: .any(error))))
            }
            else
            {
                completionHandler(.success)
            }
            
            progress.completedUnitCount = 1
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(DeleteError(record: managedRecord, code: .cancelled)))
        }
        
        return progress
    }
    
    public func updateMetadata(_ metadata: [HarmonyMetadataKey: Any], for record: RemoteRecord, completionHandler: @escaping (Result<Void>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let managedRecord = record.managedRecord else {
            completionHandler(.failure(AnyError(code: .nilManagedRecord)))
            
            return progress
        }
        
        let driveFile = GTLRDrive_File()
        driveFile.name = record.recordedObjectType + "-" + record.recordedObjectIdentifier
        driveFile.mimeType = "application/json"
        driveFile.appProperties = GTLRDrive_File_AppProperties(json: metadata)
        
        let query = GTLRDriveQuery_FilesUpdate.query(withObject: driveFile, fileId: record.identifier, uploadParameters: nil)
        
        let ticket = self.service.executeQuery(query) { (ticket, file, error) in
            if let error = error
            {
                completionHandler(.failure(UploadError(record: managedRecord, code: .any(error))))
            }
            else
            {
                completionHandler(.success)
            }
            
            progress.completedUnitCount = 1
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(UploadError(record: managedRecord, code: .cancelled)))
        }
        
        return progress
    }
}


