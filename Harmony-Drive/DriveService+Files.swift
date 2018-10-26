//
//  DriveService+Files.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 10/24/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony
import Roxas

import GoogleDrive

public extension DriveService
{
    public func upload(_ file: File, for record: LocalRecord, completionHandler: @escaping (Result<RemoteFile>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        let filename = record.recordedObjectType + "-" + record.recordedObjectIdentifier + "-" + file.identifier
        
        let fetchQuery = GTLRDriveQuery_FilesList.query()
        fetchQuery.q = "name = '\(filename)'"
        fetchQuery.fields = "nextPageToken, files(id, mimeType, name, headRevisionId, modifiedTime)"

        let ticket = self.service.executeQuery(fetchQuery) { (ticket, object, error) in
            guard error == nil else {
                return completionHandler(.failure(UploadFileError(file: file, code: .any(error!))))
            }
            
            guard let list = object as? GTLRDrive_FileList, let files = list.files else {
                return completionHandler(.failure(FetchError(code: .invalidResponse)))
            }
            
            let metadata = GTLRDrive_File()
            metadata.name = filename
            metadata.mimeType = "application/octet-stream"
            
            let uploadParameters = GTLRUploadParameters(fileURL: file.fileURL, mimeType: "application/octet-stream")
            
            let uploadQuery: GTLRDriveQuery
            
            if let file = files.first, let identifier = file.identifier
            {
                uploadQuery = GTLRDriveQuery_FilesUpdate.query(withObject: metadata, fileId: identifier, uploadParameters: uploadParameters)
            }
            else
            {
                uploadQuery = GTLRDriveQuery_FilesCreate.query(withObject: metadata, uploadParameters: uploadParameters)
            }
            
            uploadQuery.fields = "id, mimeType, name, headRevisionId, modifiedTime"
            
            let ticket = self.service.executeQuery(uploadQuery) { (ticket, driveFile, error) in
                guard error == nil else {
                    return completionHandler(.failure(UploadFileError(file: file, code: .any(error!))))
                }
                
                guard let driveFile = driveFile as? GTLRDrive_File, let remoteFile = RemoteFile(file: driveFile) else {
                    return completionHandler(.failure(UploadFileError(file: file, code: .invalidResponse)))
                }
                
                completionHandler(.success(remoteFile))
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(UploadFileError(file: file, code: .cancelled)))
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(UploadFileError(file: file, code: .cancelled)))
        }
        
        return progress
    }
    
    public func download(_ remoteFile: RemoteFile, completionHandler: @escaping (Result<File>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        let query = GTLRDriveQuery_RevisionsGet.queryForMedia(withFileId: remoteFile.remoteIdentifier, revisionId: remoteFile.versionIdentifier)
        
        let ticket = self.service.executeQuery(query) { (ticket, data, error) in
            guard error == nil else {
                return completionHandler(.failure(DownloadFileError(file: remoteFile, code: .any(error!))))
            }
            
            guard let data = data as? GTLRDataObject else {
                return completionHandler(.failure(DownloadFileError(file: remoteFile, code: .invalidResponse)))
            }
            
            do
            {
                let fileURL = FileManager.default.uniqueTemporaryURL()
                try data.data.write(to: fileURL)
                
                let file = File(identifier: remoteFile.identifier, fileURL: fileURL)
                
                completionHandler(.success(file))
            }
            catch
            {
                completionHandler(.failure(DownloadFileError(file: remoteFile, code: .any(error))))
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(DownloadFileError(file: remoteFile, code: .cancelled)))
        }
        
        return progress
    }
}
