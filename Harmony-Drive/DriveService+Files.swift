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
    func upload(_ file: File, for record: AnyRecord, metadata: [HarmonyMetadataKey: Any], context: NSManagedObjectContext, completionHandler: @escaping (Result<RemoteFile, FileError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        progress.kind = .file
        
        do
        {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.fileURL.path), let size = attributes[.size] as? Int64 else { throw FileError.doesNotExist(file.identifier) }
            progress.totalUnitCount = size
            
            let filename = String(describing: record.recordID) + "-" + file.identifier
            
            let fetchQuery = GTLRDriveQuery_FilesList.query()
            fetchQuery.q = "name = '\(filename)'"
            fetchQuery.fields = "nextPageToken, files(\(fileQueryFields))"
            fetchQuery.spaces = appDataFolder
            
            let ticket = self.service.executeQuery(fetchQuery) { (ticket, object, error) in
                do
                {
                    let files = try self.process(Result((object as? GTLRDrive_FileList)?.files, error))
                    
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
                        driveFile.parents = [appDataFolder]
                        
                        uploadQuery = GTLRDriveQuery_FilesCreate.query(withObject: driveFile, uploadParameters: uploadParameters)
                    }
                    
                    uploadQuery.fields = fileQueryFields
                    uploadQuery.executionParameters.uploadProgressBlock = { (ticket, uploadedBytes, totalBytes) in
                        progress.completedUnitCount = Int64(min(uploadedBytes, totalBytes))
                    }
                    
                    let ticket = self.service.executeQuery(uploadQuery) { (ticket, driveFile, error) in
                        context.perform {
                            do
                            {
                                let driveFile = try self.process(Result(driveFile as? GTLRDrive_File, error))
                                
                                guard let remoteFile = RemoteFile(file: driveFile, context: context) else {
                                    throw ServiceError.invalidResponse
                                }
                                
                                completionHandler(.success(remoteFile))
                            }
                            catch
                            {
                                completionHandler(.failure(FileError(file.identifier, error)))
                            }
                        }
                    }
                    
                    progress.cancellationHandler = {
                        ticket.cancel()
                        completionHandler(.failure(.other(file.identifier, GeneralError.cancelled)))
                    }
                    
                }
                catch
                {
                    completionHandler(.failure(FileError(file.identifier, error)))
                }
            }
            
            progress.cancellationHandler = {
                ticket.cancel()
                completionHandler(.failure(.other(file.identifier, GeneralError.cancelled)))
            }
        }
        catch
        {
            completionHandler(.failure(FileError(file.identifier, error)))
        }
        
        return progress
    }
    
    func download(_ remoteFile: RemoteFile, completionHandler: @escaping (Result<File, FileError>) -> Void) -> Progress
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
            do
            {
                try self.process(Result(error))
                
                guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ServiceError.invalidResponse }
                
                let file = File(identifier: fileIdentifier, fileURL: fileURL)
                completionHandler(.success(file))
            }
            catch
            {
                completionHandler(.failure(FileError(fileIdentifier, error)))
            }
        }
        
        progress.cancellationHandler = {
            fetcher.stopFetching()
            completionHandler(.failure(.other(fileIdentifier, GeneralError.cancelled)))
        }
        
        return progress
    }
    
    func delete(_ remoteFile: RemoteFile, completionHandler: @escaping (Result<Void, FileError>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        
        let fileIdentifier = remoteFile.identifier
        
        let query = GTLRDriveQuery_FilesDelete.query(withFileId: fileIdentifier)
        
        let ticket = self.service.executeQuery(query) { (ticket, file, error) in
            do
            {
                try self.process(Result(error))
                
                completionHandler(.success)
            }
            catch
            {
                completionHandler(.failure(FileError(fileIdentifier, error)))
            }            
        }
        
        progress.cancellationHandler = {
            ticket.cancel()
            completionHandler(.failure(.other(fileIdentifier, GeneralError.cancelled)))
        }
        
        return progress
    }
}
