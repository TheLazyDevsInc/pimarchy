import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "BatteryModel.js" as BatteryModel

Item {
  id: root

  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property int batteryThreshold: 10
  property string pendingPowerSource: ""
  property string activePowerProfile: ""
  readonly property bool powerSaverOnBattery: UPower.onBattery && activePowerProfile === "power-saver"
  // Same expression Panel.qml uses to hide the power panel: no UPower device
  // means no battery, so there is nothing for the 30s timer below to poll.
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }
  // Flips off the first time parseActiveProfile() comes back empty (see
  // below), so hardware with no power-profiles-daemon support -- no battery,
  // no platform_profile, no intel_pstate/amd_pstate, e.g. a Pi 400 -- stops
  // spawning busctl every two seconds once we know there is nothing to read.
  property bool powerProfilesAvailable: true

  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-battery"
    property bool notifiedLowBattery: false
  }

  function batteryPercentage() {
    return BatteryModel.batteryPercentage(UPower.displayDevice)
  }

  function isDischarging() {
    return BatteryModel.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
  }

  function checkBattery() {
    var state = BatteryModel.shouldWarnLowBattery(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging, batteryThreshold, persisted.notifiedLowBattery)
    persisted.notifiedLowBattery = state.notifiedLowBattery
    if (state.notify) sendLowBatteryWarning(state.level)
  }

  function sendLowBatteryWarning(level) {
    if (warningProcess.running) return
    warningProcess.command = [
      "omarchy-battery-low",
      String(level)
    ]
    warningProcess.running = true
  }

  function applyPowerProfile() {
    pendingPowerSource = UPower.onBattery ? "battery" : "ac"
    if (!powerProfileProcess.running) runPendingPowerProfile()
  }

  function runPendingPowerProfile() {
    powerProfileProcess.command = ["omarchy-powerprofiles-set", pendingPowerSource]
    pendingPowerSource = ""
    powerProfileProcess.running = true
  }

  function refreshPowerProfile() {
    if (!powerProfileReadProcess.running) powerProfileReadProcess.running = true
  }

  function parseActiveProfile(text) {
    // busctl --json=short prints {"type":"s","data":"balanced"}; an empty or
    // malformed reply (daemon not running) reads as no active profile.
    try {
      return String(JSON.parse(text).data || "").trim()
    } catch (e) {
      return ""
    }
  }

  Process { id: warningProcess }

  Process {
    id: powerProfileProcess
    onExited: {
      if (root.pendingPowerSource !== "") root.runPendingPowerProfile()
      root.refreshPowerProfile()
    }
  }

  Process {
    id: powerProfileReadProcess
    // Read the property straight from the daemon rather than via
    // `powerprofilesctl get`. That is a PyGObject script, and spawning a Python
    // interpreter for it every two seconds trips a CPython 3.14 shutdown race
    // (python/cpython#124619): the GLib D-Bus worker thread re-enters the
    // interpreter after finalization and the process dies with SIGSEGV,
    // leaving a core dump and a crash notification behind roughly daily.
    command: ["busctl", "--json=short", "get-property", "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles", "ActiveProfile"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var profile = root.parseActiveProfile(text)
        // An empty parse means the daemon returned nothing usable. That is
        // permanent on hardware with no power-profiles-daemon support, so
        // stop the poll below rather than keep asking forever.
        if (profile === "") root.powerProfilesAvailable = false
        root.activePowerProfile = profile
      }
    }
  }

  Timer {
    // There is no portable way to subscribe to profile changes from QML; keep
    // them visible to consumers such as the wallpaper service without requiring
    // the power panel to be open.
    interval: 2000
    running: root.powerProfilesAvailable
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshPowerProfile()
  }

  Timer {
    // No battery, nothing to check.
    interval: 30000
    running: root.batteryPresent
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkBattery()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.checkBattery()
      root.applyPowerProfile()
      root.refreshPowerProfile()
    }
  }

  Component.onCompleted: root.refreshPowerProfile()
}
