//
//  DriveService+Upload.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 10/2/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony

import GoogleDrive

public extension DriveService
{
    public func upload(_ record: LocalRecord, completionHandler: @escaping (Result<RemoteRecord>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let context = record.managedObjectContext else {
            completionHandler(.failure(UploadRecordError.nilManagedObjectContext))
            return progress
        }
        
        do
        {
            let data = try JSONEncoder().encode(record)
            
            let metadata = GTLRDrive_File()
            metadata.name = record.recordedObjectType + "-" + record.recordedObjectIdentifier
            metadata.mimeType = "application/json"

            let uploadParameters = GTLRUploadParameters(data: data, mimeType: "application/json")
            uploadParameters.shouldUploadWithSingleRequest = true
            
            let query: GTLRDriveQuery
            
            if let identifier = record.remoteRecord?.identifier
            {
                query = GTLRDriveQuery_FilesUpdate.query(withObject: metadata, fileId: identifier, uploadParameters: uploadParameters)
            }
            else
            {
                query = GTLRDriveQuery_FilesCreate.query(withObject: metadata, uploadParameters: uploadParameters)
            }
            
            query.fields = "id, mimeType, name, version, modifiedTime"
            
            let ticket = self.service.executeQuery(query) { (ticket, file, error) in
                guard error == nil else {
                    return completionHandler(.failure(error!))
                }
                
                context.perform {
                    guard let file = file as? GTLRDrive_File, let remoteRecord = RemoteRecord(file: file, status: .normal, context: context) else {
                        return completionHandler(.failure(UploadRecordError.invalidResponse))
                    }
                    
                    completionHandler(.success(remoteRecord))
                }
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(UploadRecordError.cancelled))
            }
        }
        catch
        {
            completionHandler(.failure(error))
        }
        
        return progress
    }
}
