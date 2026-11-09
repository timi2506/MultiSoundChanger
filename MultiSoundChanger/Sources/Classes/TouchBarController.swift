//
//  TouchBarController.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 09.11.2026.
//  Copyright © 2026 Dmitry Medyuho. All rights reserved.
//

import AppKit
import Foundation

// MARK: - Protocols

protocol TouchBarController: AnyObject {
    var onVolumeChanged: ((Float, Bool) -> Void)? { get set }
    func setupTouchBar()
    func updateVolume(value: Float)
}

// MARK: - DFRFoundation Private APIs

private typealias DFRSetPresenceFunc = @convention(c) (CFString, Bool) -> Void
private typealias DFRSetCloseBoxFunc = @convention(c) (Bool) -> Void

private final class DFRBridge {
    static let shared = DFRBridge()

    private let setControlStripPresenceFunc: DFRSetPresenceFunc?
    private let setSystemModalCloseBoxFunc: DFRSetCloseBoxFunc?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW) else {
            setControlStripPresenceFunc = nil
            setSystemModalCloseBoxFunc = nil
            return
        }

        if let presenceSym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") {
            setControlStripPresenceFunc = unsafeBitCast(presenceSym, to: DFRSetPresenceFunc.self)
        } else {
            setControlStripPresenceFunc = nil
        }

        if let closeBoxSym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            setSystemModalCloseBoxFunc = unsafeBitCast(closeBoxSym, to: DFRSetCloseBoxFunc.self)
        } else {
            setSystemModalCloseBoxFunc = nil
        }
    }

    var isSupported: Bool {
        return setControlStripPresenceFunc != nil
    }

    func setControlStripPresence(for identifier: NSTouchBarItem.Identifier, present: Bool) {
        setControlStripPresenceFunc?(identifier.rawValue as CFString, present)
    }

    func setSystemModalShowsCloseBoxWhenFrontMost(_ show: Bool) {
        setSystemModalCloseBoxFunc?(show)
    }
}

// MARK: - TouchBar Identifiers

private extension NSTouchBarItem.Identifier {
    static let controlStripVolume = NSTouchBarItem.Identifier("com.dmitrymedyuho.multisoundchanger.touchbar.volume")
    static let sliderItem = NSTouchBarItem.Identifier("com.dmitrymedyuho.multisoundchanger.touchbar.sliderItem")
}

// MARK: - Strip Button View

private final class ControlStripVolumeView: NSView {
    var onSwipeUpdate: ((Float) -> Void)?
    var onSwipeEnded: (() -> Void)?
    var onTap: (() -> Void)?
    var currentVolumeProvider: (() -> Float)?

    private let imageView = NSImageView()
    private var touchStartX: CGFloat = 0.0
    private var mouseStartX: CGFloat = 0.0
    private var startVolume: Float = 50.0
    private var hasSwiped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 5.0
        layer?.masksToBounds = true
        allowedTouchTypes = [.direct]

        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func setIcon(image: NSImage?) {
        imageView.image = image
    }

    // MARK: Physical Touch Handling

    override func touchesBegan(with event: NSEvent) {
        if let touch = event.touches(matching: .touching, in: self).first {
            touchStartX = touch.location(in: self).x
            startVolume = currentVolumeProvider?() ?? 50.0
            hasSwiped = false
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        }
    }

    override func touchesMoved(with event: NSEvent) {
        if let touch = event.touches(matching: .touching, in: self).first {
            let currentX = touch.location(in: self).x
            let deltaX = currentX - touchStartX

            if !hasSwiped && abs(deltaX) > 4.0 {
                hasSwiped = true
            }

            if hasSwiped {
                let sensitivity: Float = 0.45
                let newVolume = min(max(startVolume + Float(deltaX) * sensitivity, 0), 100)
                onSwipeUpdate?(newVolume)
            }
        }
    }

    override func touchesEnded(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        if hasSwiped {
            onSwipeEnded?()
        } else {
            onTap?()
        }
        hasSwiped = false
    }

    override func touchesCancelled(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        hasSwiped = false
    }

    // MARK: Mouse Fallback Handling

    override func mouseDown(with event: NSEvent) {
        mouseStartX = event.locationInWindow.x
        startVolume = currentVolumeProvider?() ?? 50.0
        hasSwiped = false
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
    }

    override func mouseDragged(with event: NSEvent) {
        let currentX = event.locationInWindow.x
        let deltaX = currentX - mouseStartX

        if !hasSwiped && abs(deltaX) > 4.0 {
            hasSwiped = true
        }

        if hasSwiped {
            let sensitivity: Float = 0.45
            let newVolume = min(max(startVolume + Float(deltaX) * sensitivity, 0), 100)
            onSwipeUpdate?(newVolume)
        }
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        if hasSwiped {
            onSwipeEnded?()
        } else {
            onTap?()
        }
        hasSwiped = false
    }
}

// MARK: - Implementation

final class TouchBarControllerImpl: NSResponder, TouchBarController, NSUserInterfaceValidations {
    var onVolumeChanged: ((Float, Bool) -> Void)?

    private let audioManager: AudioManager
    private var customTrayItem: NSCustomTouchBarItem?
    private var stripView: ControlStripVolumeView?
    private var modalTouchBar: NSTouchBar?
    private var sliderItem: NSSliderTouchBarItem?

    private var isUpdatingInternally = false

    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        teardownTouchBar()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(sliderValueChanged(_:)) {
            return true
        }
        return super.responds(to: aSelector)
    }

    func setupTouchBar() {
        guard DFRBridge.shared.isSupported else {
            return
        }

        buildModalTouchBar()
        buildControlStripItem()

        let initialVolume: Float
        if let currentVolume = audioManager.getSelectedDeviceVolume() {
            initialVolume = audioManager.isMuted ? 0 : currentVolume * 100
        } else {
            initialVolume = 50
        }
        updateVolume(value: initialVolume)
    }

    private func teardownTouchBar() {
        dismissModalTouchBar()

        guard let item = customTrayItem else {
            return
        }

        DFRBridge.shared.setControlStripPresence(for: .controlStripVolume, present: false)

        let removeSelector = Selector(("removeSystemTrayItem:"))
        if NSTouchBarItem.responds(to: removeSelector) {
            NSTouchBarItem.perform(removeSelector, with: item)
        }
    }

    private func buildControlStripItem() {
        let item = NSCustomTouchBarItem(identifier: .controlStripVolume)

        let view = ControlStripVolumeView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 40),
            view.heightAnchor.constraint(equalToConstant: 30)
        ])

        view.currentVolumeProvider = { [weak self] in
            guard let self = self else {
                return 50.0
            }
            if self.audioManager.isMuted {
                return 0.0
            }
            return (self.audioManager.getSelectedDeviceVolume() ?? 0.5) * 100.0
        }

        view.onSwipeUpdate = { [weak self] newVolume in
            self?.applyVolumeChange(newVolume, showOSD: true)
        }

        view.onSwipeEnded = { [weak self] in
            self?.dismissModalTouchBar()
        }

        view.onTap = { [weak self] in
            self?.presentModalTouchBar()
        }

        self.stripView = view
        item.view = view
        self.customTrayItem = item

        let addSelector = Selector(("addSystemTrayItem:"))
        if NSTouchBarItem.responds(to: addSelector) {
            NSTouchBarItem.perform(addSelector, with: item)
            DFRBridge.shared.setControlStripPresence(for: .controlStripVolume, present: true)
        }
    }

    private func buildModalTouchBar() {
        let modalBar = NSTouchBar()

        let sliderTouchItem = NSSliderTouchBarItem(identifier: .sliderItem)
        sliderTouchItem.slider.minValue = 0.0
        sliderTouchItem.slider.maxValue = 100.0
        sliderTouchItem.slider.isContinuous = true
        sliderTouchItem.target = self
        sliderTouchItem.action = #selector(sliderValueChanged(_:))
        sliderTouchItem.slider.target = self
        sliderTouchItem.slider.action = #selector(sliderValueChanged(_:))
        sliderTouchItem.customizationLabel = Strings.volume

        self.sliderItem = sliderTouchItem

        modalBar.defaultItemIdentifiers = [.sliderItem]
        modalBar.templateItems = [sliderTouchItem]
        self.modalTouchBar = modalBar
    }

    @objc
    func presentModalTouchBar() {
        guard let modalBar = modalTouchBar else {
            return
        }

        DFRBridge.shared.setSystemModalShowsCloseBoxWhenFrontMost(true)

        let sel = Selector(("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
        if NSTouchBar.responds(to: sel) {
            NSTouchBar.perform(sel, with: modalBar, with: NSTouchBarItem.Identifier.controlStripVolume.rawValue as NSString)
        }
    }

    @objc
    func dismissModalTouchBar() {
        guard let modalBar = modalTouchBar else {
            return
        }

        let sel = Selector(("dismissSystemModalTouchBar:"))
        if NSTouchBar.responds(to: sel) {
            NSTouchBar.perform(sel, with: modalBar)
        }
    }

    func updateVolume(value: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }

            guard !self.isUpdatingInternally else {
                return
            }

            let clamped = min(max(value, 0), 100)
            self.sliderItem?.slider.floatValue = clamped
            self.sliderItem?.doubleValue = Double(clamped)
            self.updateStripIcon(value: clamped)
        }
    }

    private func applyVolumeChange(_ newVolume: Float, showOSD: Bool) {
        isUpdatingInternally = true
        let normalized = newVolume / 100.0
        audioManager.setSelectedDeviceVolume(
            masterChannelLevel: normalized,
            leftChannelLevel: normalized,
            rightChannelLevel: normalized
        )

        sliderItem?.slider.floatValue = newVolume
        sliderItem?.doubleValue = Double(newVolume)
        updateStripIcon(value: newVolume)

        onVolumeChanged?(newVolume, showOSD)
        isUpdatingInternally = false
    }

    private func updateStripIcon(value: Float) {
        let symbolName: String
        if audioManager.isMuted {
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

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: Strings.volume),
           let symbolImage = baseImage.withSymbolConfiguration(config) {
            symbolImage.isTemplate = true
            stripView?.setIcon(image: symbolImage)
        }
    }

    @objc
    private func sliderValueChanged(_ sender: Any) {
        let floatVal: Float
        if let item = sender as? NSSliderTouchBarItem {
            floatVal = item.slider.floatValue
        } else if let slider = sender as? NSSlider {
            floatVal = slider.floatValue
        } else {
            floatVal = sliderItem?.slider.floatValue ?? 50.0
        }

        let newVolume = min(max(floatVal, 0), 100)
        applyVolumeChange(newVolume, showOSD: false)
    }
}
