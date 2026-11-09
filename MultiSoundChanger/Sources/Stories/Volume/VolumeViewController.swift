//
//  VolumeViewController.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 02.04.17.
//  Copyright © 2017 Dmitry Medyuho. All rights reserved.
//

import AudioToolbox
import Cocoa
import SwiftUI

// MARK: - Volume View Model

final class VolumeViewModel: ObservableObject {
    @Published var volume: Double = 50.0

    var onVolumeChanged: ((Float) -> Void)?
    private var isUpdatingFromExternal = false

    func updateVolumeFromSlider(_ newVolume: Double) {
        volume = newVolume
        guard !isUpdatingFromExternal else {
            return
        }
        onVolumeChanged?(Float(newVolume))
    }

    func updateVolumeFromExternal(_ newVolume: Float) {
        let clamped = Double(newVolume.clamped(to: 0...100))
        guard abs(volume - clamped) > 0.1 else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }
            self.isUpdatingFromExternal = true
            self.volume = clamped
            self.isUpdatingFromExternal = false
        }
    }
}

// MARK: - Volume Slider View

struct VolumeSliderItem: View {
    @ObservedObject var viewModel: VolumeViewModel

    init(viewModel: VolumeViewModel = VolumeViewModel()) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sound")
                .bold()
                .padding(.vertical, 2.5)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 13.5)
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.updateVolumeFromSlider($0) }
                    ),
                    in: 0...100
                )
                .tint(.blue)
                .accentColor(.blue)

                Image(systemName: "speaker.wave.3.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 13.5)
                    .foregroundColor(.secondary)
            }
        }
        .environment(\.controlActiveState, .active)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Explicit width is required for NSHostingView sizing in menus
        .frame(width: 300)
    }
}

// MARK: - Menu Hosting View

final class MenuHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool {
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            needsLayout = true
            needsDisplay = true
        }
    }
}

// MARK: - Volume View Controller

final class VolumeViewController: NSViewController {
    let viewModel: VolumeViewModel
    weak var statusBarController: StatusBarController?
    var audioManager: AudioManager?

    init(viewModel: VolumeViewModel = VolumeViewModel()) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        setupViewModel()
    }

    required init?(coder: NSCoder) {
        self.viewModel = VolumeViewModel()
        super.init(coder: coder)
        setupViewModel()
    }

    override func loadView() {
        let hostingView = MenuHostingView(rootView: VolumeSliderItem(viewModel: viewModel))
        let fittingHeight = hostingView.fittingSize.height
        let height = fittingHeight > 0 ? fittingHeight : 57
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        self.view = hostingView
    }

    func prepareForDisplay() {
        guard let currentVolume = audioManager?.getSelectedDeviceVolume() else {
            return
        }
        let volume = audioManager?.isMuted == true ? 0 : currentVolume * 100
        viewModel.volume = Double(volume)
        if let hosting = view as? MenuHostingView<VolumeSliderItem> {
            hosting.rootView = VolumeSliderItem(viewModel: viewModel)
        }
    }

    private func setupViewModel() {
        viewModel.onVolumeChanged = { [weak self] value in
            self?.changeDeviceVolume(value: value / 100)
            self?.statusBarController?.changeStatusItemImage(value: value)
            self?.statusBarController?.touchBarController?.updateVolume(value: value)
        }
    }

    private func changeDeviceVolume(value: Float) {
        audioManager?.setSelectedDeviceVolume(masterChannelLevel: value, leftChannelLevel: value, rightChannelLevel: value)
    }

    func updateSliderVolume(volume: Float) {
        viewModel.updateVolumeFromExternal(volume)
    }
}
