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

import GoogleDrive

extension RemoteFile
{
    init?(file: GTLRDrive_File)
    {        
        guard
            let remoteIdentifier = file.identifier,
            let versionIdentifier = file.headRevisionId
        else { return nil }
        
        guard let components = file.name?.split(separator: "-"), let identifier = components.last else { return nil }
        
        self.init(identifier: String(identifier), remoteIdentifier: remoteIdentifier, versionIdentifier: versionIdentifier)
    }
}
