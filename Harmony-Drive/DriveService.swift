//
//  DriveService.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 1/25/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import Harmony

import GoogleSignIn
import GoogleDrive

let fileQueryFields = "id, mimeType, name, headRevisionId, modifiedTime, appProperties"

public class DriveService: NSObject, Service
{
    public static let shared = DriveService()

    public let localizedName = NSLocalizedString("Google Drive", comment: "")
    public let identifier = "com.rileytestut.Harmony.Drive"

    public var clientID: String? {
        didSet {
            GIDSignIn.sharedInstance().clientID = self.clientID
        }
    }

    let service = GTLRDriveService()

    private var authorizationCompletionHandlers = [(Result<Void>) -> Void]()
    private var deauthorizationCompletionHandlers = [(Result<Void>) -> Void]()
    
    private weak var presentingViewController: UIViewController?

    private override init()
    {
        var scopes = GIDSignIn.sharedInstance().scopes as? [String] ?? []
        if !scopes.contains(kGTLRAuthScopeDriveAppdata)
        {
            scopes.append(kGTLRAuthScopeDriveAppdata)
            GIDSignIn.sharedInstance().scopes = scopes
        }
        
        super.init()
        
        self.service.shouldFetchNextPages = true
    }
}

public extension DriveService
{
    func authenticate(withPresentingViewController viewController: UIViewController, completionHandler: @escaping (Result<Void>) -> Void)
    {
        self.authorizationCompletionHandlers.append(completionHandler)

        GIDSignIn.sharedInstance().uiDelegate = self
        GIDSignIn.sharedInstance().delegate = self

        GIDSignIn.sharedInstance().signIn()
    }

    func authenticateInBackground(completionHandler: @escaping (Result<Void>) -> Void)
    {
        self.authorizationCompletionHandlers.append(completionHandler)

        GIDSignIn.sharedInstance().delegate = self

        // Must run on main thread.
        DispatchQueue.main.async {
            GIDSignIn.sharedInstance().signInSilently()
        }
    }
    
    func deauthenticate(completionHandler: @escaping (Result<Void>) -> Void)
    {
        self.deauthorizationCompletionHandlers.append(completionHandler)
        
        GIDSignIn.sharedInstance().delegate = self
        
        GIDSignIn.sharedInstance().disconnect()
    }
}

extension DriveService: GIDSignInDelegate
{
    public func sign(_ signIn: GIDSignIn!, didSignInFor user: GIDGoogleUser!, withError error: Error!)
    {
        let result: Result<Void>

        if let user = user
        {
            self.service.authorizer = user.authentication.fetcherAuthorizer()

            result = .success
        }
        else
        {
            do
            {
                throw error
            }
            catch let error as NSError where error.domain == kGIDSignInErrorDomain && error.code == GIDSignInErrorCode.canceled.rawValue
            {
                result = .failure(AuthenticationError(code: .cancelled))
            }
            catch let error as NSError where error.domain == kGIDSignInErrorDomain && error.code == GIDSignInErrorCode.hasNoAuthInKeychain.rawValue
            {
                result = .failure(AuthenticationError(code: .noSavedCredentials))
            }
            catch
            {
                result = .failure(AuthenticationError(code: .any(error)))
            }
        }

        self.authorizationCompletionHandlers.forEach { $0(result) }
        self.authorizationCompletionHandlers = []
    }
    
    public func sign(_ signIn: GIDSignIn!, didDisconnectWith user: GIDGoogleUser!, withError error: Error!)
    {
        let result: Result<Void>
        
        if let error = error
        {
            result = .failure(AuthenticationError(code: .any(error)))
        }
        else
        {
            result = .success
        }
        
        self.deauthorizationCompletionHandlers.forEach { $0(result) }
        self.deauthorizationCompletionHandlers = []
    }
}

extension DriveService: GIDSignInUIDelegate
{
    public func sign(_ signIn: GIDSignIn!, present viewController: UIViewController!)
    {
        self.presentingViewController?.present(viewController, animated: true, completion: nil)
    }

    public func sign(_ signIn: GIDSignIn!, dismiss viewController: UIViewController!)
    {
        self.presentingViewController?.dismiss(animated: true, completion: nil)
    }
}

