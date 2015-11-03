//
//  ViewController.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 10/28/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa
import AudioToolbox

struct ProcessorEntry {
    let inputChannel: Int
    var network: String = ""
    var config: SyllableDetectorConfig?
    let outputChannel: Int
    
    init(inputChannel: Int, outputChannel: Int) {
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
    }
}

class Processor: AudioInputInterfaceDelegate {
    // input and output interfaces
    let interfaceInput: AudioInputInterface
    let interfaceOutput: AudioOutputInterface
    
    // processor entries
    let entries: [ProcessorEntry]
    let detectors: [SyllableDetector]
    let channels: [Int]
    
    // high duration
    let highDuration = 0.001 // 1ms
    
    init(deviceInput: AudioInterface.AudioDevice, deviceOutput: AudioInterface.AudioDevice, entries: [ProcessorEntry]) throws {
        // setup processor entries
        self.entries = entries.filter {
            return $0.config != nil
        }
        
        // setup processor detectors
        self.detectors = self.entries.map {
            return SyllableDetector(config: $0.config!)
        }
        
        // setup channels
        var channels = [Int](count: 1 + (self.entries.map { return max($0.inputChannel, $0.outputChannel) }.maxElement() ?? -1), repeatedValue: -1)
        for (i, p) in self.entries.enumerate() {
            channels[p.inputChannel] = i
        }
        self.channels = channels
        
        // setup input and output devices
        interfaceInput = AudioInputInterface(deviceID: deviceInput.deviceID)
        interfaceOutput = AudioOutputInterface(deviceID: deviceOutput.deviceID)
        
        // set self as delegate
        interfaceInput.delegate = self
        
        try interfaceOutput.initializeAudio()
        try interfaceInput.initializeAudio()
    }
    
    deinit {
        DLog("stop")
        interfaceInput.tearDownAudio()
        interfaceOutput.tearDownAudio()
    }
    
    func receiveAudioFrom(interface: AudioInputInterface, fromChannel channel: Int, withData data: UnsafeMutablePointer<Float>, ofLength length: Int) {
        DLog("\(channel) \(data[0])")
        
        // valid channel
        guard channel < channels.count else { return }
        
        // get index
        let index = channels[channel]
        guard index >= 0 else { return }
        
        // append audio samples
        detectors[index].appendAudioData(data, withSamples: length)
        
        if detectors[channel].seenSyllable() {
            DLog("play") // for debugging
            
            // play high
            interfaceOutput.createHighOutput(entries[index].outputChannel, forDuration: highDuration)
        }
    }
}

class ViewControllerProcessor: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    @IBOutlet weak var buttonLoad: NSButton!
    @IBOutlet weak var buttonToggle: NSButton!
    @IBOutlet weak var tableChannels: NSTableView!
    
    // devices
    var deviceInput: AudioInterface.AudioDevice!
    var deviceOutput: AudioInterface.AudioDevice!
    
    var processorEntries = [ProcessorEntry]()
    var processor: Processor?
    
    var isRunning = false {
        didSet {
            tableChannels.enabled = !isRunning
            buttonLoad.enabled = !isRunning
            buttonToggle.title = (isRunning ? "Stop" : "Start")
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableChannels.target = self
        tableChannels.doubleAction = "tableRowDoubleClicked"
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        if nil == deviceInput || nil == deviceOutput {
            fatalError("Input and output devices must be already defined.")
        }
        
        // reload table
        tableChannels.reloadData()
    }
    
    func setupEntries(input deviceInput: AudioInterface.AudioDevice, output deviceOutput: AudioInterface.AudioDevice) {
        // store input and output
        self.deviceInput = deviceInput
        self.deviceOutput = deviceOutput
        
        // get input pairs
        let inputChannels: Int
        if 0 < deviceInput.buffersInput.count {
            inputChannels = Int(deviceInput.buffersInput[0].mNumberChannels)
        }
        else {
            inputChannels = 0
        }
        
        let outputChannels: Int
        if 0 < deviceOutput.buffersOutput.count {
            outputChannels = Int(deviceOutput.buffersOutput[0].mNumberChannels)
        }
        else {
            outputChannels = 0
        }
        
        // for each pair, create an entry
        let numEntries = min(inputChannels, outputChannels)
        processorEntries = (0..<numEntries).map {
            return ProcessorEntry(inputChannel: $0, outputChannel: $0)
        }
    }
    
    @IBAction func toggle(sender: NSButton) {
        if isRunning {
            // stop everything
            processor = nil
            
            // clear is running
            isRunning = false
        }
        else {
            // create process
            do {
                processor = try Processor(deviceInput: deviceInput, deviceOutput: deviceOutput, entries: processorEntries)
            }
            catch {
                // show an error message
                let alert = NSAlert()
                alert.messageText = "Unable to initialize audio"
                alert.informativeText = "There was an error initializing the audio interfaces: \(error)."
                alert.addButtonWithTitle("Ok")
                alert.beginSheetModalForWindow(self.view.window!, completionHandler:nil)
                return
            }
            
            // set as running
            isRunning = true
        }
    }
    
    override func viewWillDisappear() {
        // clear processor
        processor = nil
        isRunning = false
        
        super.viewWillDisappear()
    }
    
    func numberOfRowsInTableView(tableView: NSTableView) -> Int {
        let inputChannels: Int, outputChannels: Int
        
        if nil != deviceInput && 0 < deviceInput.buffersInput.count {
            inputChannels = deviceInput.buffersInput.reduce(0) {
                return $0 + Int($1.mNumberChannels)
            }
        }
        else {
            inputChannels = 0
        }
        
        if nil != deviceOutput && 0 < deviceOutput.buffersOutput.count {
            outputChannels = deviceOutput.buffersOutput.reduce(0) {
                return $0 + Int($1.mNumberChannels)
            }
        }
        else {
            outputChannels = 0
        }
        
        return min(inputChannels, outputChannels)
    }
    
    func tableView(tableView: NSTableView, objectValueForTableColumn tableColumn: NSTableColumn?, row: Int) -> AnyObject? {
        guard let identifier = tableColumn?.identifier else { return nil }
        guard row < processorEntries.count else { return nil }
        
        switch identifier {
        case "ColumnInput", "ColumnOutput": return "Channel \(row + 1)"
        case "ColumnInLevel", "ColumnOutLevel": return NSNumber(float: 0.0)
        case "ColumnNetwork": return nil == processorEntries[row].config ? "Not Selected" : processorEntries[row].network
        default: return nil
        }
    }
    
    func tableRowDoubleClicked() {
        guard !isRunning else { return } // can not select when running
        guard 0 <= tableChannels.clickedColumn else { return } // valid column
        guard "ColumnNetwork" == tableChannels.tableColumns[tableChannels.clickedColumn].identifier else { return } // double clicked network column
        
        // show network selector
        loadNetworkForRow(tableChannels.clickedRow)
    }
    
    @IBAction func loadNetwork(sender: NSButton) {
        if 0 > tableChannels.selectedRow { // no row selected...
            // find next row needing a network
            for (i, p) in processorEntries.enumerate() {
                if nil == p.config {
                    loadNetworkForRow(i)
                    break
                }
            }
        }
        else {
            // load network for row
            loadNetworkForRow(tableChannels.selectedRow)
        }
    }
    
    func loadNetworkForRow(row: Int) {
        guard !isRunning else { return } // can not select when running
        guard row < processorEntries.count else { return }
        
        let panel = NSOpenPanel()
        panel.title = "Select Network Definition"
        panel.allowedFileTypes = ["txt"]
        panel.allowsOtherFileTypes = false
        
        // callback for handling response
        let cb = {
            (result: Int) -> Void in
            // check again, just in case
            guard !self.isRunning else { return } // can not select when running
            guard row < self.processorEntries.count else { return }
            
            // make sure ok was pressed
            if NSFileHandlingPanelOKButton == result {
                if let url = panel.URL, let path = url.path {
                    do {
                        // load file
                        let config = try SyllableDetectorConfig(fromTextFile: path)
                        self.processorEntries[row].config = config
                        self.processorEntries[row].network = url.lastPathComponent ?? "Unknown Network"
                    }
                    catch {
                        // unable to load
                        let alert = NSAlert()
                        alert.messageText = "Unable to load"
                        alert.informativeText = "The text file could not be successfully loaded: \(error)."
                        alert.addButtonWithTitle("Ok")
                        alert.beginSheetModalForWindow(self.view.window!, completionHandler:nil)
                        
                        // clear selected
                        self.processorEntries[row].network = ""
                        self.processorEntries[row].config = nil
                    }
                    
                    // reload table
                    self.tableChannels.reloadData()
                }
            }
        }
        
        // show
        panel.beginSheetModalForWindow(self.view.window!, completionHandler: cb)
    }
}

