//
//  DriveService+Versions.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 11/20/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony
import Roxas

import GoogleDrive

public extension DriveService
{
    func fetchVersions(for record: AnyRecord, completionHandler: @escaping (Result<[Version], RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        record.perform { (managedRecord) -> Void in
            guard let remoteRecord = managedRecord.remoteRecord else { return completionHandler(.failure(RecordError(record, ValidationError.nilRemoteRecord))) }
            
            let query = GTLRDriveQuery_RevisionsList.query(withFileId: remoteRecord.identifier)
            
            let ticket = self.service.executeQuery(query) { (ticket, object, error) in
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
                
                guard let revisionList = object as? GTLRDrive_RevisionList, let revisions = revisionList.revisions else {
                    return completionHandler(.failure(RecordError(record, NetworkError.invalidResponse)))
                }
                
                let versions = revisions.lazy.compactMap(Version.init(revision:)).reversed()
                completionHandler(.success(Array(versions)))
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(.other(record, GeneralError.cancelled)))
            }
        }

        return progress
    }
}
