//
//  RemoteRecord+File.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 1/30/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony

import GoogleDrive

extension RemoteRecord
{
    convenience init?(file: GTLRDrive_File, status: ManagedRecord.Status, context: NSManagedObjectContext)
    {
        guard let mimeType = file.mimeType, mimeType == "application/json" else { return nil }
        
        guard
            let identifier = file.identifier,
            let versionIdentifier = file.version?.description,
            let versionDate = file.modifiedTime?.date
        else { return nil }
        
        guard let components = file.name?.split(separator: "-", maxSplits: 1), components.count == 2 else { return nil }
        
        let recordedObjectType = String(components[0])
        let recordedObjectIdentifier = String(components[1])
                
        self.init(identifier: identifier, versionIdentifier: versionIdentifier, versionDate: versionDate, recordedObjectType: recordedObjectType, recordedObjectIdentifier: recordedObjectIdentifier, status: status, managedObjectContext: context)
    }
}
