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
    func fetchAllRemoteRecords(context: NSManagedObjectContext, completionHandler: @escaping (Result<(Set<RemoteRecord>, Data), FetchError>) -> Void) -> Progress
    {
        var filesResult: Result<Set<RemoteRecord>, FetchError>?
        var tokenResult: Result<Data, FetchError>?
        
        let progress = Progress.discreteProgress(totalUnitCount: 2)
        
        let filesQuery = GTLRDriveQuery_FilesList.query()
        filesQuery.pageSize = 1000
        filesQuery.spaces = appDataFolder
        filesQuery.fields = "nextPageToken, files(\(fileQueryFields))"
        filesQuery.completionBlock = { (ticket, object, error) in
            guard error == nil else {
                filesResult = .failure(FetchError(NetworkError.connectionFailed(error!)))
                return
            }
            
            guard let list = object as? GTLRDrive_FileList, let files = list.files else {
                filesResult = .failure(FetchError(NetworkError.invalidResponse))
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
                tokenResult = .failure(FetchError(NetworkError.connectionFailed(error!)))
                return
            }

            guard let result = object as? GTLRDrive_StartPageToken, let token = result.startPageToken else {
                tokenResult = .failure(FetchError(NetworkError.invalidResponse))
                return
            }

            guard let data = token.data(using: .utf8) else {
                tokenResult = .failure(FetchError(NetworkError.invalidResponse))
                return
            }

            tokenResult = .success(data)
            
            progress.completedUnitCount += 1
        }
        
        let batchQuery = GTLRBatchQuery(queries: [filesQuery, changeTokenQuery])

        let ticket = self.service.executeQuery(batchQuery) { (ticket, object, error) in
            guard let filesResult = filesResult, let tokenResult = tokenResult else { return completionHandler(.failure(FetchError.other(.unknown))) }
            
            let result: Result<(Set<RemoteRecord>, Data), FetchError>
            
            switch (filesResult, tokenResult)
            {
            case (.success(let records), .success(let token)): result = .success((records, token))
            case (.success, .failure(let error)): result = .failure(FetchError(NetworkError.connectionFailed(error)))
            case (.failure(let error), .success): result = .failure(FetchError(NetworkError.connectionFailed(error)))
            case (.failure(let error), .failure): result = .failure(FetchError(NetworkError.connectionFailed(error)))
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
            completionHandler(.failure(FetchError.other(.cancelled)))
        }
        
        return progress
    }
    
    func fetchChangedRemoteRecords(changeToken: Data, context: NSManagedObjectContext, completionHandler: @escaping (Result<(Set<RemoteRecord>, Set<String>, Data), FetchError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let pageToken = String(data: changeToken, encoding: .utf8) else {
            completionHandler(.failure(FetchError.invalidChangeToken(changeToken)))
            return progress
        }
        
        let query = GTLRDriveQuery_ChangesList.query(withPageToken: pageToken)
        query.fields = "nextPageToken, newStartPageToken, changes(fileId, type, removed, file(\(fileQueryFields)))"
        query.includeRemoved = true
        query.pageSize = 1000
        query.spaces = appDataFolder
        
        let ticket = self.service.executeQuery(query) { (ticket, object, error) in
            guard error == nil else { return completionHandler(.failure(FetchError(NetworkError.connectionFailed(error!)))) }
            
            guard let result = object as? GTLRDrive_ChangeList,
                let newPageToken = result.newStartPageToken,
                let tokenData = newPageToken.data(using: .utf8),
                let changes = result.changes
            else { return completionHandler(.failure(FetchError(NetworkError.invalidResponse))) }
            
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
            completionHandler(.failure(FetchError.other(.cancelled)))
        }
        
        return progress
    }
}

public extension DriveService
{
    func upload(_ record: AnyRecord, metadata: [HarmonyMetadataKey: Any], context: NSManagedObjectContext, completionHandler: @escaping (Result<RemoteRecord, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        record.perform { (managedRecord) -> Void in
            guard let localRecord = managedRecord.localRecord else { return completionHandler(.failure(RecordError(record, ValidationError.nilLocalRecord))) }
            
            do
            {
                let data = try JSONEncoder().encode(localRecord)
                
                let file = GTLRDrive_File()
                file.name = String(describing: record.recordID)
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
                    file.parents = [appDataFolder]
                    
                    query = GTLRDriveQuery_FilesCreate.query(withObject: file, uploadParameters: uploadParameters)
                }
                
                query.fields = fileQueryFields
                
                let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                    context.perform {
                        guard error == nil else {
                            return completionHandler(.failure(RecordError(record, NetworkError.connectionFailed(error!))))
                        }
                        
                        guard let file = file as? GTLRDrive_File, let remoteRecord = RemoteRecord(file: file, status: .normal, context: context) else {
                            return completionHandler(.failure(RecordError(record, NetworkError.invalidResponse)))
                        }
                        
                        completionHandler(.success(remoteRecord))
                        
                        progress.completedUnitCount += 1
                    }
                }
                
                progress.cancellationHandler = {
                    ticket.cancel()
                    completionHandler(.failure(.other(record, .cancelled)))
                }
            }
            catch
            {
                completionHandler(.failure(RecordError(record, error)))
            }
        }
        
        return progress
    }
    
    func download(_ record: AnyRecord, version: Version, context: NSManagedObjectContext, completionHandler: @escaping (Result<LocalRecord, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        record.perform { (managedRecord) -> Void in
            guard let remoteRecord = managedRecord.remoteRecord else { return completionHandler(.failure(RecordError(record, ValidationError.nilRemoteRecord))) }
            
            let query = GTLRDriveQuery_RevisionsGet.queryForMedia(withFileId: remoteRecord.identifier, revisionId: version.identifier)
            
            let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                context.perform {
                    guard error == nil else {
                        if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain && error.code == 404
                        {
                            return completionHandler(.failure(.doesNotExist(record)))
                        }
                        else
                        {
                            return completionHandler(.failure(RecordError(record, NetworkError.connectionFailed(error!))))
                        }
                    }
                    
                    guard let file = file as? GTLRDataObject else {
                        return completionHandler(.failure(RecordError(record, NetworkError.invalidResponse)))
                    }
                    
                    do
                    {
                        let decoder = JSONDecoder()
                        decoder.managedObjectContext = context
                        
                        let record = try decoder.decode(LocalRecord.self, from: file.data)
                        completionHandler(.success(record))
                        
                        progress.completedUnitCount += 1
                    }
                    catch
                    {
                        completionHandler(.failure(RecordError(record, error)))
                    }
                }
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(.other(record, .cancelled)))
            }
        }
        
        return progress
    }
    
    func delete(_ record: AnyRecord, completionHandler: @escaping (Result<Void, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        record.perform { (managedRecord) -> Void in
            guard let remoteRecord = managedRecord.remoteRecord else { return completionHandler(.failure(RecordError(record, ValidationError.nilRemoteRecord))) }
            
            let query = GTLRDriveQuery_FilesDelete.query(withFileId: remoteRecord.identifier)
            
            let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                if let error = error
                {
                    if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain && error.code == 404
                    {
                        completionHandler(.failure(.doesNotExist(record)))
                    }
                    else
                    {
                        completionHandler(.failure(RecordError(record, error)))
                    }
                }
                else
                {
                    completionHandler(.success)
                }
                
                progress.completedUnitCount = 1
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(.other(record, .cancelled)))
            }
        }
        
        return progress
    }
    
    public func updateMetadata(_ metadata: [HarmonyMetadataKey: Any], for record: AnyRecord, completionHandler: @escaping (Result<Void, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        record.perform { (managedRecord) -> Void in
            guard let remoteRecord = managedRecord.remoteRecord else { return completionHandler(.failure(RecordError(record, ValidationError.nilRemoteRecord))) }
            
            let driveFile = GTLRDrive_File()
            driveFile.name = String(describing: record.recordID)
            driveFile.mimeType = "application/json"
            driveFile.appProperties = GTLRDrive_File_AppProperties(json: metadata)
            
            let query = GTLRDriveQuery_FilesUpdate.query(withObject: driveFile, fileId: remoteRecord.identifier, uploadParameters: nil)
            
            let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                if let error = error
                {
                    if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain && error.code == 404
                    {
                        completionHandler(.failure(.doesNotExist(record)))
                    }
                    else
                    {
                        completionHandler(.failure(RecordError(record, error)))
                    }
                }
                else
                {
                    completionHandler(.success)
                }
                
                progress.completedUnitCount = 1
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(.other(record, .cancelled)))
            }
        }
        
        return progress
    }
}


