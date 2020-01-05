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

let fileQueryFields = "id, mimeType, name, headRevisionId, modifiedTime, appProperties, size"
let appDataFolder = "appDataFolder"

private let kGoogleHTTPErrorDomain = "com.google.HTTPStatus"

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
    
    private var authorizationCompletionHandlers = [(Result<Account, AuthenticationError>) -> Void]()
    
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
    func authenticate(withPresentingViewController viewController: UIViewController, completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void)
    {
        self.authorizationCompletionHandlers.append(completionHandler)

        GIDSignIn.sharedInstance().uiDelegate = self
        GIDSignIn.sharedInstance().delegate = self

        GIDSignIn.sharedInstance().signIn()
    }

    func authenticateInBackground(completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void)
    {
        self.authorizationCompletionHandlers.append(completionHandler)

        GIDSignIn.sharedInstance().delegate = self

        // Must run on main thread.
        DispatchQueue.main.async {
            GIDSignIn.sharedInstance().signInSilently()
        }
    }
    
    func deauthenticate(completionHandler: @escaping (Result<Void, DeauthenticationError>) -> Void)
    {
        GIDSignIn.sharedInstance().signOut()
        completionHandler(.success)
    }
    
    func authenticateManually(withAccessToken accessToken: String, completionHandler: @escaping (Result<Account, AuthenticationError>) -> Void) {
        // need to do
    }
    
    func getAccessToken() -> String? {
        // need to do
        return nil
    }
}

extension DriveService
{
    func process<T>(_ result: Result<T, Error>) throws -> T
    {
        do
        {
            do
            {
                let value = try result.get()
                return value
            }
            catch let error where error._domain == kGIDSignInErrorDomain
            {
                switch error._code
                {
                case GIDSignInErrorCode.canceled.rawValue: throw GeneralError.cancelled
                case GIDSignInErrorCode.hasNoAuthInKeychain.rawValue: throw AuthenticationError.noSavedCredentials
                default: throw ServiceError(error)
                }
            }
            catch let error where error._domain == kGTLRErrorObjectDomain || error._domain == kGoogleHTTPErrorDomain
            {
                switch error._code
                {
                case 400, 401: throw AuthenticationError.tokenExpired
                case 403: throw ServiceError.rateLimitExceeded
                case 404: throw ServiceError.itemDoesNotExist
                default: throw ServiceError(error)
                }
            }
            catch
            {
                throw ServiceError(error)
            }
        }
        catch let error as HarmonyError
        {
            throw error
        }
        catch
        {
            assertionFailure("Non-HarmonyError thrown from DriveService.process(_:)")
            throw error
        }
    }
}

extension DriveService: GIDSignInDelegate
{
    public func sign(_ signIn: GIDSignIn!, didSignInFor user: GIDGoogleUser!, withError error: Error!)
    {
        let result: Result<Account, AuthenticationError>

        do
        {
            let user = try self.process(Result(user, error))
            
            self.service.authorizer = user.authentication.fetcherAuthorizer()
            
            let account = Account(name: user.profile.name, emailAddress: user.profile.email)
            result = .success(account)
        }
        catch
        {
            result = .failure(AuthenticationError(error))
        }
        
        // Reset self.authorizationCompletionHandlers _before_ calling all the completion handlers.
        // This stops us from accidentally calling completion handlers twice in some instances.
        let completionHandlers = self.authorizationCompletionHandlers
        self.authorizationCompletionHandlers.removeAll()
        
        completionHandlers.forEach { $0(result) }
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

