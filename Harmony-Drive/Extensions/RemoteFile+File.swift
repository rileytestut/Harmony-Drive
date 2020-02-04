//
//  RemoteFile+File.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 10/24/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony

import GoogleAPIClientForREST

extension RemoteFile
{
    convenience init?(file: GTLRDrive_File, context: NSManagedObjectContext)
    {        
        guard
            let remoteIdentifier = file.identifier,
            let versionIdentifier = file.headRevisionId,
            let size = file.size as? Int,
            let metadata = file.appProperties?.json as? [HarmonyMetadataKey: String]
        else { return nil }
        
        try? self.init(remoteIdentifier: remoteIdentifier, versionIdentifier: versionIdentifier, size: size, metadata: metadata, context: context)
    }
}
