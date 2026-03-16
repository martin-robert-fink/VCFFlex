//
//  ShareViewController.swift
//  VCFFlexShare
//
//  Created by Martin Fink on 3/16/26.
//

import Cocoa
import SwiftUI

class ShareViewController: NSViewController {

    override func loadView() {
        let hostingView = NSHostingView(rootView: ShareExtensionView())
        self.view = hostingView
        self.preferredContentSize = NSSize(width: 400, height: 500)
    }
}

struct ShareExtensionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("VCFFlex")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Contact data will appear here")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
