//
//  FriendWidgetBundle.swift
//  FriendWidget
//

import SwiftUI
import WidgetKit

@main
struct FriendWidgetBundle: WidgetBundle {
    var body: some Widget {
        FriendWidget()
        FriendLiveActivity()
    }
}
