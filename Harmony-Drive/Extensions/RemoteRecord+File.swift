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

import GoogleAPIClientForREST

extension RemoteRecord
{
    convenience init?(file: GTLRDrive_File, status: RecordStatus, context: NSManagedObjectContext)
    {
        guard let mimeType = file.mimeType, mimeType == "application/json" else { return nil }
        
        guard
            let identifier = file.identifier,
            let versionIdentifier = file.headRevisionId,
            let versionDate = file.modifiedTime?.date,
            let metadata = file.appProperties?.json as? [HarmonyMetadataKey: String]
        else { return nil }
                
        try? self.init(identifier: identifier, versionIdentifier: versionIdentifier, versionDate: versionDate, metadata: metadata, status: status, context: context)
    }
}
