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
    public func upload(_ file: File, for record: LocalRecord, metadata: [HarmonyMetadataKey: Any], context: NSManagedObjectContext, completionHandler: @escaping (Result<RemoteFile>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        let filename = String(describing: record.recordID) + "-" + file.identifier
        
        let fetchQuery = GTLRDriveQuery_FilesList.query()
        fetchQuery.q = "name = '\(filename)'"
        fetchQuery.fields = "nextPageToken, files(\(fileQueryFields))"

        let ticket = self.service.executeQuery(fetchQuery) { (ticket, object, error) in
            guard error == nil else {
                return completionHandler(.failure(_UploadFileError(file: file, code: .any(error!))))
            }
            
            guard let list = object as? GTLRDrive_FileList, let files = list.files else {
                return completionHandler(.failure(_UploadFileError(file: file, code: .invalidResponse)))
            }
            
            let driveFile = GTLRDrive_File()
            driveFile.name = filename
            driveFile.mimeType = "application/octet-stream"
            driveFile.appProperties = GTLRDrive_File_AppProperties(json: metadata)
            
            let uploadParameters = GTLRUploadParameters(fileURL: file.fileURL, mimeType: "application/octet-stream")
            
            let uploadQuery: GTLRDriveQuery
            
            if let file = files.first, let identifier = file.identifier
            {
                uploadQuery = GTLRDriveQuery_FilesUpdate.query(withObject: driveFile, fileId: identifier, uploadParameters: uploadParameters)
            }
            else
            {
                uploadQuery = GTLRDriveQuery_FilesCreate.query(withObject: driveFile, uploadParameters: uploadParameters)                
            }
            
            uploadQuery.fields = fileQueryFields
            
            let executionParameters = GTLRServiceExecutionParameters()
            executionParameters.uploadProgressBlock = { (ticket, uploadedBytes, totalBytes) in
                progress.totalUnitCount = Int64(totalBytes)
                progress.completedUnitCount = Int64(uploadedBytes)
            }
            
            let ticket = self.service.executeQuery(uploadQuery) { (ticket, driveFile, error) in
                context.perform {
                    guard error == nil else {
                        return completionHandler(.failure(_UploadFileError(file: file, code: .any(error!))))
                    }
                    
                    guard let driveFile = driveFile as? GTLRDrive_File, let remoteFile = RemoteFile(file: driveFile, context: context) else {
                        return completionHandler(.failure(_UploadFileError(file: file, code: .invalidResponse)))
                    }
                    
                    completionHandler(.success(remoteFile))
                }
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(_UploadFileError(file: file, code: .cancelled)))
            }
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(_UploadFileError(file: file, code: .cancelled)))
        }
        
        return progress
    }
    
    public func download(_ remoteFile: RemoteFile, completionHandler: @escaping (Result<File>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        progress.totalUnitCount = Int64(remoteFile.size)
        progress.kind = .file
        
        let fileIdentifier = remoteFile.identifier
        
        let query = GTLRDriveQuery_RevisionsGet.queryForMedia(withFileId: remoteFile.remoteIdentifier, revisionId: remoteFile.versionIdentifier)
        let downloadRequest = self.service.request(for: query) as URLRequest
        
        let fileURL = FileManager.default.uniqueTemporaryURL()
        
        let fetcher = self.service.fetcherService.fetcher(with: downloadRequest)
        fetcher.destinationFileURL = fileURL
        fetcher.downloadProgressBlock = { (bytesWritten, totalBytesWritten, totalBytes) in
            progress.completedUnitCount = totalBytesWritten
        }
        fetcher.beginFetch { (_, error) in
            guard error == nil else {
                if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain && error.code == 404
                {
                    return completionHandler(.failure(_DownloadFileError(file: remoteFile, code: .fileDoesNotExist)))
                }
                else
                {
                    return completionHandler(.failure(_DownloadFileError(file: remoteFile, code: .any(error!))))
                }
            }
            
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return completionHandler(.failure(_DownloadFileError(file: remoteFile, code: .invalidResponse)))
            }
            
            let file = File(identifier: fileIdentifier, fileURL: fileURL)
            completionHandler(.success(file))
        }

        progress.cancellationHandler = {
            fetcher.stopFetching()
            completionHandler(.failure(_DownloadFileError(file: remoteFile, code: .cancelled)))
        }
        
        return progress
    }
    
    public func delete(_ remoteFile: RemoteFile, completionHandler: @escaping (Result<Void>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        let query = GTLRDriveQuery_FilesDelete.query(withFileId: remoteFile.remoteIdentifier)
        
        let ticket = self.service.executeQuery(query) { (ticket, file, error) in
            if let error = error
            {
                if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain && error.code == 404
                {
                    completionHandler(.failure(_DeleteFileError(file: remoteFile, code: .fileDoesNotExist)))
                }
                else
                {
                    completionHandler(.failure(_DeleteFileError(file: remoteFile, code: .any(error))))
                }
            }
            else
            {
                completionHandler(.success)
            }
            
            progress.completedUnitCount = 1
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(_DeleteFileError(file: remoteFile, code: .cancelled)))
        }
        
        return progress
    }
}
