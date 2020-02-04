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

import GoogleAPIClientForREST

public extension DriveService
{
    func fetchVersions(for record: AnyRecord, completionHandler: @escaping (Result<[Version], RecordError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)

        do
        {
            try record.perform { (managedRecord) -> Void in
                guard let remoteRecord = managedRecord.remoteRecord else { throw ValidationError.nilRemoteRecord }
                
                let query = GTLRDriveQuery_RevisionsList.query(withFileId: remoteRecord.identifier)
                
                let ticket = self.service.executeQuery(query) { (ticket, object, error) in
                    do
                    {
                        let revisions = try self.process(Result((object as? GTLRDrive_RevisionList)?.revisions, error))
                        
                        let versions = revisions.lazy.compactMap(Version.init(revision:)).reversed()
                        completionHandler(.success(Array(versions)))
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
