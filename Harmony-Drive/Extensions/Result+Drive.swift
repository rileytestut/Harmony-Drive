//
//  Result+Drive.swift
//  Harmony-Drive
//
//  Created by Riley Testut on 3/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Harmony

extension Result where Failure == Error
{
    init(_ value: Success?, _ error: Error?)
    {
        switch (value, error)
        {
        case (let value?, _): self = .success(value)
        case (_, let error?): self = .failure(error)
        case (nil, nil): self = .failure(ServiceError.invalidResponse)
        }
    }
}

extension Result where Success == Void, Failure == Error
{
    init(_ error: Error?)
    {
        if let error = error
        {
            self = .failure(error)
        }
        else
        {
            self = .success
        }
    }
}
