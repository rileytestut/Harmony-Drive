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
            do
            {
                let files = try self.process(Result((object as? GTLRDrive_FileList)?.files, error))
                
                context.performAndWait {
                    let records = files.compactMap { RemoteRecord(file: $0, status: .normal, context: context) }
                    filesResult = .success(Set(records))
                }
            }
            catch
            {
                filesResult = .failure(FetchError(error))
            }
            
            progress.completedUnitCount += 1
        }
        
        let changeTokenQuery = GTLRDriveQuery_ChangesGetStartPageToken.query()
        changeTokenQuery.completionBlock = { (ticket, object, error) in
            do
            {
                let result = try self.process(Result(object as? GTLRDrive_StartPageToken, error))
                guard let token = result.startPageToken, let data = token.data(using: .utf8) else { throw ServiceError.invalidResponse }
                
                tokenResult = .success(data)
            }
            catch
            {
                tokenResult = .failure(FetchError(error))
            }
            
            progress.completedUnitCount += 1
        }
        
        let batchQuery = GTLRBatchQuery(queries: [filesQuery, changeTokenQuery])
        
        let ticket = self.service.executeQuery(batchQuery) { (ticket, object, error) in
            let result: Result<(Set<RemoteRecord>, Data), FetchError>
            
            do
            {
                guard let filesResult = filesResult, let tokenResult = tokenResult else { throw GeneralError.unknown }
                
                switch (filesResult, tokenResult)
                {
                case (.success(let records), .success(let token)):
                    result = .success((records, token))
                    
                case (.success, .failure(let error)),
                     (.failure(let error), .success),
                     (.failure(let error), .failure):
                    throw ServiceError(error)
                }
            }
            catch
            {
                result = .failure(FetchError(error))
                
                // Delete inserted RemoteRecords if filesResult is success, but the overall result is failure.
                if let filesResult = filesResult, case .success(let records) = filesResult
                {
                    context.performAndWait {
                        records.forEach { context.delete($0) }
                    }
                }
            }
            
            context.perform {
                completionHandler(result)
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(FetchError.other(GeneralError.cancelled)))
        }
        
        return progress
    }
    
    func fetchChangedRemoteRecords(changeToken: Data, context: NSManagedObjectContext, completionHandler: @escaping (Result<(Set<RemoteRecord>, Set<String>, Data), FetchError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        do
        {
            guard let pageToken = String(data: changeToken, encoding: .utf8) else { throw FetchError.invalidChangeToken(changeToken) }
            
            let query = GTLRDriveQuery_ChangesList.query(withPageToken: pageToken)
            query.fields = "nextPageToken, newStartPageToken, changes(fileId, type, removed, file(\(fileQueryFields)))"
            query.includeRemoved = true
            query.pageSize = 1000
            query.spaces = appDataFolder
            
            let ticket = self.service.executeQuery(query) { (ticket, object, error) in
                do
                {
                    let result = try self.process(Result(object as? GTLRDrive_ChangeList, error))
                    
                    guard let newPageToken = result.newStartPageToken, let tokenData = newPageToken.data(using: .utf8), let changes = result.changes
                        else { throw ServiceError.invalidResponse }
                    
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
                        
                        completionHandler(.success((updatedRecords, deletedIDs, tokenData)))
                    }
                }
                catch
                {
                    completionHandler(.failure(FetchError(error)))
                }
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(FetchError.other(GeneralError.cancelled)))
            }
        }
        catch
        {
            completionHandler(.failure(FetchError(error)))
        }
        
        return progress
    }
}

public extension DriveService
{
    func upload(_ record: AnyRecord, metadata: [HarmonyMetadataKey: Any], context: NSManagedObjectContext, completionHandler: @escaping (Result<RemoteRecord, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        do
        {
            try record.perform { (managedRecord) -> Void in
                guard let localRecord = managedRecord.localRecord else { throw ValidationError.nilLocalRecord }
                
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
                        do
                        {
                            let file = try self.process(Result(file as? GTLRDrive_File, error))
                            
                            guard let remoteRecord = RemoteRecord(file: file, status: .normal, context: context) else {
                                throw ServiceError.invalidResponse
                            }
                            
                            completionHandler(.success(remoteRecord))
                        }
                        catch
                        {
                            completionHandler(.failure(RecordError(record, error)))
                        }
                    }
                }
                
                progress.cancellationHandler = {
                    ticket.cancel()
                    completionHandler(.failure(.other(record, GeneralError.cancelled)))
                }
            }
        }
        catch
        {
            completionHandler(.failure(RecordError(record, error)))
        }
        
        return progress
    }
    
    func download(_ record: AnyRecord, version: Version, context: NSManagedObjectContext, completionHandler: @escaping (Result<LocalRecord, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        do
        {
            try record.perform { (managedRecord) -> Void in
                guard let remoteRecord = managedRecord.remoteRecord else { throw ValidationError.nilRemoteRecord }
                
                let query = GTLRDriveQuery_RevisionsGet.queryForMedia(withFileId: remoteRecord.identifier, revisionId: version.identifier)
                
                let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                    context.perform {
                        do
                        {
                            let file = try self.process(Result(file as? GTLRDataObject, error))
                            
                            let decoder = JSONDecoder()
                            decoder.managedObjectContext = context
                            
                            let record = try decoder.decode(LocalRecord.self, from: file.data)
                            completionHandler(.success(record))
                        }
                        catch
                        {
                            completionHandler(.failure(RecordError(record, error)))
                        }
                    }
                }
                
                progress.cancellationHandler = {
                    ticket.cancel()
                    completionHandler(.failure(.other(record, GeneralError.cancelled)))
                }
            }
        }
        catch
        {
            completionHandler(.failure(RecordError(record, error)))
        }
        
        return progress
    }
    
    func delete(_ record: AnyRecord, completionHandler: @escaping (Result<Void, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        do
        {
            try record.perform { (managedRecord) -> Void in
                guard let remoteRecord = managedRecord.remoteRecord else { throw ValidationError.nilRemoteRecord }
                
                let query = GTLRDriveQuery_FilesDelete.query(withFileId: remoteRecord.identifier)
                
                let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                    do
                    {
                        try self.process(Result(error))
                        
                        completionHandler(.success)
                    }
                    catch
                    {
                        completionHandler(.failure(RecordError(record, error)))
                    }
                }
                
                progress.cancellationHandler = {
                    ticket.cancel()
                    completionHandler(.failure(.other(record, GeneralError.cancelled)))
                }
            }
        }
        catch
        {
            completionHandler(.failure(RecordError(record, error)))
        }
        
        return progress
    }
    
    func updateMetadata(_ metadata: [HarmonyMetadataKey: Any], for record: AnyRecord, completionHandler: @escaping (Result<Void, RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        do
        {
            try record.perform { (managedRecord) -> Void in
                guard let remoteRecord = managedRecord.remoteRecord else { throw ValidationError.nilRemoteRecord }
                
                let driveFile = GTLRDrive_File()
                driveFile.name = String(describing: record.recordID)
                driveFile.mimeType = "application/json"
                driveFile.appProperties = GTLRDrive_File_AppProperties(json: metadata)
                
                let query = GTLRDriveQuery_FilesUpdate.query(withObject: driveFile, fileId: remoteRecord.identifier, uploadParameters: nil)
                
                let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                    do
                    {                        
                        try self.process(Result(error))
                        
                        completionHandler(.success)
                    }
                    catch
                    {
                        completionHandler(.failure(RecordError(record, error)))
                    }
                }
                
                progress.cancellationHandler = {
                    ticket.cancel()
                    completionHandler(.failure(.other(record, GeneralError.cancelled)))
                }
            }
        }
        catch
        {
            completionHandler(.failure(RecordError(record, error)))
        }
        
        return progress
    }
}
