//
//  AudioManager.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 15.11.2020.
//  Copyright © 2020 Dmitry Medyuho. All rights reserved.
//

import AudioToolbox
import Foundation

// MARK: - Protocols

protocol AudioManager: class {
    func getDefaultOutputDevice() -> AudioDeviceID
    func getOutputDevices() -> [AudioDeviceID: String]?
    func selectDevice(deviceID: AudioDeviceID)
    func getSelectedDeviceVolume() -> Float?
    func setSelectedDeviceVolume(masterChannelLevel: Float, leftChannelLevel: Float, rightChannelLevel: Float)
    func isSelectedDeviceMuted() -> Bool
    func toggleMute()

    var isMuted: Bool { get }
    var onVolumeChanged: ((Float) -> Void)? { get set }
    var onDefaultDeviceChanged: ((AudioDeviceID) -> Void)? { get set }
}

// MARK: - Implementation

final class AudioManagerImpl: AudioManager {
    private let audio: Audio = AudioImpl()
    private let devices: [AudioDeviceID: String]?
    private var selectedDevice: AudioDeviceID?

    var onVolumeChanged: ((Float) -> Void)?
    var onDefaultDeviceChanged: ((AudioDeviceID) -> Void)?

    private var observedDevices: [AudioDeviceID] = []
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        devices = audio.getOutputDevices()
        printDevices()
        setupSystemListener()
    }

    deinit {
        removeSystemListener()
        removeDeviceListeners()
    }

    func getDefaultOutputDevice() -> AudioDeviceID {
        return audio.getDefaultOutputDevice()
    }

    func getOutputDevices() -> [AudioDeviceID: String]? {
        return devices
    }

    func isAggregateDevice(deviceID: AudioDeviceID) -> Bool {
        return audio.isAggregateDevice(deviceID: deviceID)
    }

    func selectDevice(deviceID: AudioDeviceID) {
        removeDeviceListeners()
        selectedDevice = deviceID
        audio.setOutputDevice(newDeviceID: deviceID)
        setupDeviceListeners(for: deviceID)
        Logger.debug(Constants.InnerMessages.selectDevice(deviceID: String(deviceID)))
    }

    func getSelectedDeviceVolume() -> Float? {
        guard let selectedDevice = selectedDevice else {
            return nil
        }
        
        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)
            
            for device in aggregatedDevices {
                if audio.isOutputDevice(deviceID: device) {
                    return audio.getDeviceVolume(deviceID: device).max()
                }
            }
        } else {
            return audio.getDeviceVolume(deviceID: selectedDevice).max()
        }
        
        return nil
    }
    
    func setSelectedDeviceVolume(masterChannelLevel: Float, leftChannelLevel: Float, rightChannelLevel: Float) {
        guard let selectedDevice = selectedDevice else {
            return
        }
        
        let isMute = masterChannelLevel < Constants.muteVolumeLowerbound
            && leftChannelLevel < Constants.muteVolumeLowerbound
            && rightChannelLevel < Constants.muteVolumeLowerbound
        
        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)
            
            for device in aggregatedDevices {
                audio.setDeviceVolume(
                    deviceID: device,
                    masterChannelLevel: masterChannelLevel,
                    leftChannelLevel: leftChannelLevel,
                    rightChannelLevel: rightChannelLevel
                )
                audio.setDeviceMute(deviceID: device, isMute: isMute)
            }
        } else {
            audio.setDeviceVolume(
                deviceID: selectedDevice,
                masterChannelLevel: masterChannelLevel,
                leftChannelLevel: leftChannelLevel,
                rightChannelLevel: rightChannelLevel
            )
            audio.setDeviceMute(deviceID: selectedDevice, isMute: isMute)
        }
    }
    
    func setSelectedDeviceMute(isMute: Bool) {
        guard let selectedDevice = selectedDevice else {
            return
        }
        
        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)
            
            for device in aggregatedDevices {
                audio.setDeviceMute(deviceID: device, isMute: isMute)
            }
        } else {
            audio.setDeviceMute(deviceID: selectedDevice, isMute: isMute)
        }
    }
    
    func isSelectedDeviceMuted() -> Bool {
        guard let selectedDevice = selectedDevice else {
            return false
        }
        
        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)
            
            guard let device = aggregatedDevices.first else {
                return false
            }
            
            return audio.isDeviceMuted(deviceID: device)
        } else {
            return audio.isDeviceMuted(deviceID: selectedDevice)
        }
    }
    
    func toggleMute() {
        if isSelectedDeviceMuted() {
            setSelectedDeviceMute(isMute: false)
            let volume = getSelectedDeviceVolume() ?? 0
            setSelectedDeviceVolume(masterChannelLevel: volume, leftChannelLevel: volume, rightChannelLevel: volume)
        } else {
            setSelectedDeviceMute(isMute: true)
        }
    }
    
    var isMuted: Bool {
        return isSelectedDeviceMuted()
    }
    
    private func printDevices() {
        guard let devices = devices else {
            return
        }
        Logger.debug(Constants.InnerMessages.outputDevices)
        for device in devices {
            Logger.debug(Constants.InnerMessages.debugDevice(deviceID: String(device.key), deviceName: device.value))
        }
    }

    private func setupSystemListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        )

        systemListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let newDevice = self.getDefaultOutputDevice()
            self.onDefaultDeviceChanged?(newDevice)
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            systemListenerBlock!
        )
    }

    private func removeSystemListener() {
        guard let systemListenerBlock = systemListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            systemListenerBlock
        )
    }

    private func setupDeviceListeners(for deviceID: AudioDeviceID) {
        let targets = isAggregateDevice(deviceID: deviceID)
            ? audio.getAggregateDeviceSubDeviceList(deviceID: deviceID).filter { audio.isOutputDevice(deviceID: $0) }
            : [deviceID]

        observedDevices = targets

        deviceListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            guard let volume = self.getSelectedDeviceVolume() else { return }
            let correctedVolume = self.isMuted ? 0 : volume * 100
            self.onVolumeChanged?(correctedVolume)
        }

        for dev in targets {
            addPropertyListeners(to: dev)
        }
    }

    private func addPropertyListeners(to devID: AudioDeviceID) {
        guard let block = deviceListenerBlock else { return }
        let elements: [AudioObjectPropertyElement] = [0, 1, 2]
        for elem in elements {
            var volAddress = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
                mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
                mElement: elem
            )
            AudioObjectAddPropertyListenerBlock(devID, &volAddress, DispatchQueue.main, block)
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyMute),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        )
        AudioObjectAddPropertyListenerBlock(devID, &muteAddress, DispatchQueue.main, block)
    }

    private func removeDeviceListeners() {
        guard let block = deviceListenerBlock else { return }
        for dev in observedDevices {
            let elements: [AudioObjectPropertyElement] = [0, 1, 2]
            for elem in elements {
                var volAddress = AudioObjectPropertyAddress(
                    mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
                    mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
                    mElement: elem
                )
                AudioObjectRemovePropertyListenerBlock(dev, &volAddress, DispatchQueue.main, block)
            }
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioDevicePropertyMute),
                mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
                mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
            )
            AudioObjectRemovePropertyListenerBlock(dev, &muteAddress, DispatchQueue.main, block)
        }
        observedDevices.removeAll()
        deviceListenerBlock = nil
    }
}

