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
    public func fetchVersions(for record: RemoteRecord, completionHandler: @escaping (Result<[Version]>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        guard let managedRecord = record.managedRecord else {
            completionHandler(.failure(_AnyError(code: .nilManagedRecord)))
            return progress
        }
                
        let query = GTLRDriveQuery_RevisionsList.query(withFileId: record.identifier)
        
        let ticket = self.service.executeQuery(query) { (ticket, object, error) in
            guard error == nil else {
                if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain && error.code == 404
                {
                    return completionHandler(.failure(_FetchVersionsError(record: managedRecord, code: .fileDoesNotExist)))
                }
                else
                {
                    return completionHandler(.failure(_FetchVersionsError(record: managedRecord, code: .any(error!))))
                }
            }
                        
            guard let revisionList = object as? GTLRDrive_RevisionList, let revisions = revisionList.revisions else {
                return completionHandler(.failure(_FetchVersionsError(record: managedRecord, code: .invalidResponse)))
            }
            
            let versions = revisions.lazy.compactMap(Version.init(revision:)).reversed()
            completionHandler(.success(Array(versions)))
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(_FetchVersionsError(record: managedRecord, code: .cancelled)))
        }
        
        return progress
    }
}
