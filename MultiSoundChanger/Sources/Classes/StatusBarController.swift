//
//  StatusBarController.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 15.11.2020.
//  Copyright © 2020 Dmitry Medyuho. All rights reserved.
//

import AudioToolbox
import Cocoa
import QuartzCore

// MARK: - Protocols

protocol StatusBarController: AnyObject {
    var touchBarController: TouchBarController? { get }
    var mediaManager: MediaManager? { get set }
    func createMenu()
    func changeStatusItemImage(value: Float)
    func updateVolume(value: Float)
}

// MARK: - Extensions

extension StatusBarControllerImpl {
    enum MenuItem {
        case volume
        case slider
        case output
        case separator
        case soundPreferences
        case audioSetup
        case quit
    }
}

// MARK: - Views

private final class StatusImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

// MARK: - Implementation

final class StatusBarControllerImpl: NSObject, StatusBarController, NSMenuDelegate {
    let touchBarController: TouchBarController?
    var mediaManager: MediaManager?

    private let statusItem = NSStatusBar.system.statusItem(withLength: 30)
    private let statusImageView = StatusImageView()
    private let volumeController: VolumeViewController
    private let audioManager: AudioManager
    private var currentSymbolName: String?
    
    init(audioManager: AudioManager, mediaManager: MediaManager? = nil) {
        self.audioManager = audioManager
        self.mediaManager = mediaManager

        let touchBarCtrl = TouchBarControllerImpl(audioManager: audioManager)
        self.touchBarController = touchBarCtrl

        self.volumeController = VolumeViewController()
        self.volumeController.audioManager = audioManager

        super.init()

        self.volumeController.statusBarController = self

        setupAudioManagerCallbacks()
        setupTouchBarCallbacks()
    }

    private func setupTouchBarCallbacks() {
        touchBarController?.onVolumeChanged = { [weak self] volume, showOSD in
            self?.volumeController.updateSliderVolume(volume: volume)
            self?.changeStatusItemImage(value: volume)
            if showOSD {
                self?.mediaManager?.showOSD(volume: volume, chicletsCount: Constants.chicletsCount)
            }
        }
    }

    private func setupAudioManagerCallbacks() {
        audioManager.onVolumeChanged = { [weak self] volume in
            self?.updateVolume(value: volume)
        }

        audioManager.onDefaultDeviceChanged = { [weak self] newDeviceID in
            self?.handleDefaultDeviceChanged(newDeviceID: newDeviceID)
        }
    }

    private func handleDefaultDeviceChanged(newDeviceID: AudioDeviceID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }

            if let items = self.statusItem.menu?.items {
                for item in items where item.tag != 0 {
                    item.state = (item.tag == Int(newDeviceID)) ? .on : .off
                }
            }
            self.selectDevice(device: newDeviceID)
        }
    }

    private func setupStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.image = nil
        button.title = ""

        if statusImageView.superview == nil {
            statusImageView.wantsLayer = true
            statusImageView.imageScaling = .scaleProportionallyDown
            statusImageView.contentTintColor = .controlTextColor
            statusImageView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusImageView)

            NSLayoutConstraint.activate([
                statusImageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                statusImageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                statusImageView.widthAnchor.constraint(equalToConstant: 20),
                statusImageView.heightAnchor.constraint(equalToConstant: 20)
            ])
        }
    }

    func createMenu() {
        setupStatusButton()
        touchBarController?.setupTouchBar()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let sliderItem = getMenuItem(by: .slider)
        let outputItem = getMenuItem(by: .output)
        let firstSeparatorItem = getMenuItem(by: .separator)
        let soundPreferencesItem = getMenuItem(by: .soundPreferences)
        let audioSetupItem = getMenuItem(by: .audioSetup)
        let secondSeparatorItem = getMenuItem(by: .separator)
        let quitItem = getMenuItem(by: .quit)

        menu.addItem(sliderItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(outputItem)
        setOutputDeviceList(for: menu)
        menu.addItem(firstSeparatorItem)
        menu.addItem(soundPreferencesItem)
        menu.addItem(audioSetupItem)
        menu.addItem(secondSeparatorItem)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func changeStatusItemImage(value: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }

            let symbolName: String
            if self.audioManager.isMuted {
                symbolName = "speaker.slash.fill"
            } else if value <= 0.001 {
                symbolName = "speaker.fill"
            } else if value <= 100.0 / 3.0 {
                symbolName = "speaker.wave.1.fill"
            } else if value <= (100.0 / 3.0) * 2.0 {
                symbolName = "speaker.wave.2.fill"
            } else {
                symbolName = "speaker.wave.3.fill"
            }

            self.updateStatusIcon(symbolName: symbolName)
        }
    }

    private func updateStatusIcon(symbolName: String) {
        guard currentSymbolName != symbolName else {
            return
        }

        let config = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: Strings.volume),
              let symbolImage = baseImage.withSymbolConfiguration(config) else {
            return
        }

        symbolImage.isTemplate = true

        let previousSymbol = currentSymbolName
        currentSymbolName = symbolName

        guard let previous = previousSymbol else {
            statusImageView.image = symbolImage
            return
        }

        let isMuteTransition = (previous == "speaker.slash.fill" || symbolName == "speaker.slash.fill")

        if isMuteTransition {
            if #available(macOS 14.0, *) {
                statusImageView.setSymbolImage(symbolImage, contentTransition: .replace.byLayer)
                statusImageView.addSymbolEffect(.bounce.byLayer, options: .nonRepeating)
            } else {
                statusImageView.image = symbolImage
            }
        } else {
            let transition = CATransition()
            transition.duration = 0.15
            transition.type = .fade
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            statusImageView.layer?.add(transition, forKey: kCATransition)
            statusImageView.image = symbolImage
        }
    }

    func updateVolume(value: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.volumeController.updateSliderVolume(volume: value)
            self?.changeStatusItemImage(value: value)
            self?.touchBarController?.updateVolume(value: value)
        }
    }
    
    private func getMenuItem(by type: MenuItem) -> NSMenuItem {
        switch type {
        case .volume:
            let item = NSMenuItem(title: Strings.volume, action: nil, keyEquivalent: Constants.Keys.empty.rawValue)
            item.isEnabled = false
            return item
            
        case .slider:
            let item = NSMenuItem(title: String(), action: nil, keyEquivalent: Constants.Keys.empty.rawValue)
            item.view = volumeController.view
            return item
            
        case .output:
            let item = NSMenuItem(title: Strings.output, action: nil, keyEquivalent: Constants.Keys.empty.rawValue)
            item.isEnabled = false
            return item
            
        case .separator:
            return NSMenuItem.separator()
                
        case .soundPreferences:
            let item = NSMenuItem(
                title: Strings.soundPreferences,
                action: #selector(menuSoundPreferencesAction),
                keyEquivalent: Constants.Keys.empty.rawValue
            )
            item.target = self
            return item
            
        case .audioSetup:
            let item = NSMenuItem(title: Strings.audioDevices, action: #selector(menuAudioSetupAction), keyEquivalent: Constants.Keys.empty.rawValue)
            item.target = self
            return item
            
        case .quit:
            let item = NSMenuItem(title: Strings.quit, action: #selector(menuQuitAction), keyEquivalent: Constants.Keys.q.rawValue)
            item.target = self
            return item
        }
    }
    
    private func setOutputDeviceList(for menu: NSMenu) {
        guard let devices = audioManager.getOutputDevices() else {
            return
        }
        
        let defaultDevice = audioManager.getDefaultOutputDevice()
        
        for device in devices {
            let item = NSMenuItem(
                title: truncate(device.value, length: Constants.optionMaxLength),
                action: #selector(menuItemAction),
                keyEquivalent: String()
            )
            item.target = self
            item.tag = Int(device.key)
            
            if device.key == defaultDevice {
                item.state = .on
                selectDevice(device: defaultDevice)
            }
            
            menu.addItem(item)
        }
    }
    
    private func selectDevice(device: AudioDeviceID) {
        audioManager.selectDevice(deviceID: device)
        guard let volume = audioManager.getSelectedDeviceVolume() else {
            return
        }
        let correctedVolume = audioManager.isMuted ? 0 : volume * 100
        volumeController.updateSliderVolume(volume: correctedVolume)
        changeStatusItemImage(value: correctedVolume)
    }
    
    private func truncate(_ string: String, length: Int, trailing: String = "…") -> String {
        if string.count > length {
            return String(string.prefix(length)) + trailing
        } else {
            return string
        }
    }
    
    @objc
    private func menuItemAction(sender: NSMenuItem) {
        guard let items = statusItem.menu?.items else {
            return
        }
        for item in items {
            if item == sender {
                item.state = .on
                let deviceID = AudioDeviceID(item.tag)
                selectDevice(device: deviceID)
            } else {
                item.state = NSControl.StateValue.off
            }
        }
    }
    
    @objc
    private func menuSoundPreferencesAction() {
        Runner.shell("open -b \(Constants.AppBundleIdentifier.systemPreferences) \(Constants.SystemPreferencesPane.sound)")
    }
    
    @objc
    private func menuAudioSetupAction() {
        Runner.launchApplication(bundleIndentifier: Constants.AppBundleIdentifier.audioDevices, options: .default)
    }
    
    @objc
    private func menuQuitAction() {
        NSApplication.shared.terminate(self)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        volumeController.prepareForDisplay()
    }
}
