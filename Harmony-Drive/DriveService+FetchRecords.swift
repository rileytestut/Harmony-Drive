//
//  DriveService+FetchRecords.swift
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
        filesQuery.fields = "nextPageToken, files(id, mimeType, name, version, modifiedTime)"
        filesQuery.completionBlock = { (ticket, object, error) in
            guard error == nil else {
                filesResult = .failure(error! as NSError)
                return
            }
            
            guard let list = object as? GTLRDrive_FileList, let files = list.files else {
                filesResult = .failure(FetchRecordsError.invalidFormat)
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
                tokenResult = .failure(error! as NSError)
                return
            }

            guard let result = object as? GTLRDrive_StartPageToken, let token = result.startPageToken else {
                tokenResult = .failure(FetchRecordsError.invalidFormat)
                return
            }

            guard let data = token.data(using: .utf8) else {
                tokenResult = .failure(FetchRecordsError.invalidFormat)
                return
            }

            tokenResult = .success(data)
            
            progress.completedUnitCount += 1
        }
        
        let batchQuery = GTLRBatchQuery(queries: [filesQuery, changeTokenQuery])

        let ticket = self.service.executeQuery(batchQuery) { (ticket, object, error) in
            guard let filesResult = filesResult, let tokenResult = tokenResult else { return completionHandler(.failure(FetchRecordsError.unknown)) }
            
            let result: Result<(Set<RemoteRecord>, Data)>
            
            switch (filesResult, tokenResult)
            {
            case (.success(let records), .success(let token)): result = .success((records, token))
            case (.success, .failure(let error)): result = .failure(error)
            case (.failure(let error), .success): result = .failure(error)
            case (.failure(let error), .failure): result = .failure(error)
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
            completionHandler(.failure(FetchRecordsError.cancelled))
        }
        
        return progress
    }
    
    func fetchChangedRemoteRecords(changeToken: Data, context: NSManagedObjectContext, completionHandler: @escaping (Result<(Set<RemoteRecord>, Set<String>, Data)>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let pageToken = String(data: changeToken, encoding: .utf8) else {
            completionHandler(.failure(FetchRecordsError.invalidChangeToken(changeToken)))
            return progress
        }
        
        let query = GTLRDriveQuery_ChangesList.query(withPageToken: pageToken)
        query.fields = "nextPageToken, newStartPageToken, changes(fileId, type, removed, file(id, mimeType, name, version, modifiedTime))"
        query.includeRemoved = true
        query.pageSize = 1000
        
        let ticket = self.service.executeQuery(query) { (ticket, object, error) in
            guard error == nil else { return completionHandler(.failure(FetchRecordsError.service(error! as NSError))) }
            
            guard let result = object as? GTLRDrive_ChangeList,
                let newPageToken = result.newStartPageToken,
                let tokenData = newPageToken.data(using: .utf8),
                let changes = result.changes
            else { return completionHandler(.failure(FetchRecordsError.invalidFormat)) }
            
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
            completionHandler(.failure(FetchRecordsError.cancelled))
        }
        
        return progress
    }
}


