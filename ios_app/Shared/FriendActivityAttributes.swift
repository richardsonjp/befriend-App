//
//  FriendActivityAttributes.swift
//  befriend (app + widget)
//

import ActivityKit
import PetCore

/// The friend's Lock Screen / Dynamic Island activity. The backend's push-to-start payload uses
/// "attributes-type": "FriendActivityAttributes" and "attributes": {"friendName": …}.
nonisolated struct FriendActivityAttributes: ActivityAttributes {
    typealias ContentState = FriendSurfaceState

    let friendName: String
}
