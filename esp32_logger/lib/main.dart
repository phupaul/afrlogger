import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Dashboard(),
    );
  }
}

class LogData {
  final DateTime timestamp;
  final double rpm;
  final double afr;
  final double map;

  LogData({
    required this.timestamp,
    required this.rpm,
    required this.afr,
    required this.map,
  });

  // Convert to JSON
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.millisecondsSinceEpoch,
    'rpm': rpm,
    'afr': afr,
    'map': map,
  };

  // Create from JSON
  factory LogData.fromJson(Map<String, dynamic> json) => LogData(
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
    rpm: json['rpm'],
    afr: json['afr'],
    map: json['map'],
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with SingleTickerProviderStateMixin {
  double rpm = 0;
  double afr = 0;
  double map = 0;

  final Guid serviceUUID = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final Guid charUUID = Guid("57049b24-3c16-4079-b038-76cebc5aa16d");

  String statusMessage = "Initializing...";
  
  List<LogData> logHistory = [];
  bool isLogging = false;
  
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    loadLogData(); // Load saved data first
    checkPermissions();
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // Load saved log data from storage
  Future<void> loadLogData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString('logHistory');
      
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        logHistory = jsonList.map((json) => LogData.fromJson(json)).toList();
        setState(() {});
        print('Loaded ${logHistory.length} log entries');
      }
    } catch (e) {
      print('Error loading log data: $e');
    }
  }

  // Save log data to storage
  Future<void> saveLogData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = logHistory.map((log) => log.toJson()).toList();
      final jsonString = json.encode(jsonList);
      await prefs.setString('logHistory', jsonString);
      print('Saved ${logHistory.length} log entries');
    } catch (e) {
      print('Error saving log data: $e');
    }
  }

  // Check permissions first
  void checkPermissions() async {
    setState(() => statusMessage = "Checking permissions...");
    
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    bool allGranted = statuses.values.every((status) => status.isGranted);
    
    if (allGranted) {
      print("All permissions granted");
      startBle();
    } else {
      setState(() => statusMessage = "Permissions denied. Please grant Bluetooth & Location!");
      print("Permissions denied: $statuses");
    }
  }

  // ================= BLE =================
  void startBle() async {
    try {
      // Check Bluetooth adapter
      var adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        setState(() => statusMessage = "Please turn on Bluetooth!");
        print("Bluetooth is OFF");
        return;
      }

      setState(() => statusMessage = "Scanning for ESP32_Logger...");
      print("Starting BLE scan...");
      
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      FlutterBluePlus.scanResults.listen((results) async {
        print("Scan results: ${results.length} devices found");
        for (ScanResult r in results) {
          print("Found device: ${r.device.name} | ${r.device.id}");
          
          if (r.device.name == "ESP32_Logger") {
            print("ESP32_Logger found! Connecting...");
            await FlutterBluePlus.stopScan();
            setState(() => statusMessage = "Connecting...");

            try {
              await r.device.connect(timeout: const Duration(seconds: 10));
              print("Connected successfully!");
              setState(() => statusMessage = "Connected!");
              discoverServices(r.device);
            } catch (e) {
              print("Connection error: $e");
              setState(() => statusMessage = "Connection failed: $e");
            }
            break;
          }
        }
      });

      // Handle scan timeout
      await Future.delayed(const Duration(seconds: 11));
      if (statusMessage == "Scanning for ESP32_Logger...") {
        setState(() => statusMessage = "ESP32_Logger not found. Retrying...");
        print("Scan timeout, retrying...");
        await Future.delayed(const Duration(seconds: 2));
        startBle();
      }
    } catch (e) {
      print("BLE Error: $e");
      setState(() => statusMessage = "Error: $e");
    }
  }

  void discoverServices(BluetoothDevice device) async {
    try {
      print("Discovering services...");
      List<BluetoothService> services = await device.discoverServices();
      print("Found ${services.length} services");

      for (var service in services) {
        print("Service: ${service.uuid}");
        if (service.uuid == serviceUUID) {
          print("Target service found!");
          for (var char in service.characteristics) {
            print("Characteristic: ${char.uuid}");
            if (char.uuid == charUUID) {
              print("Target characteristic found! Setting up notifications...");
              await char.setNotifyValue(true);
              
              char.lastValueStream.listen((value) {
                if (value.isNotEmpty) {
                  String data = utf8.decode(value);
                  print("Received data: $data");
                  parseData(data);
                }
              });
              
              setState(() => statusMessage = "Receiving data...");
              print("Notifications enabled!");
            }
          }
        }
      }
    } catch (e) {
      print("Service discovery error: $e");
      setState(() => statusMessage = "Discovery error: $e");
    }
  }

  void parseData(String data) {
    // Ví dụ: RPM=1234;AFR=13.8;MAP=62
    final parts = data.split(';');
    for (var p in parts) {
      if (p.startsWith("RPM=")) rpm = double.parse(p.substring(4));
      if (p.startsWith("AFR=")) afr = double.parse(p.substring(4));
      if (p.startsWith("MAP=")) map = double.parse(p.substring(4));
    }
    
    // Log data if logging is enabled
    if (isLogging) {
      logHistory.add(LogData(
        timestamp: DateTime.now(),
        rpm: rpm,
        afr: afr,
        map: map,
      ));
      
      // Keep only last 1000 entries to avoid memory issues
      if (logHistory.length > 1000) {
        logHistory.removeAt(0);
      }
      
      // Auto-save every 10 entries to avoid too frequent writes
      if (logHistory.length % 10 == 0) {
        saveLogData();
      }
    }
    
    setState(() {});
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Status bar
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                border: Border(bottom: BorderSide(color: const Color(0xFF00E5FF), width: 2)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Gauge Logger",
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    statusMessage,
                    style: TextStyle(
                      color: statusMessage.contains("Receiving") 
                          ? Colors.green 
                          : Colors.orange,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            // TabBar
            Container(
              color: Colors.grey.shade900,
              child: TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFF00E5FF),
                labelColor: const Color(0xFF00E5FF),
                unselectedLabelColor: Colors.grey,
                tabs: const [
                  Tab(text: "Dashboard"),
                  Tab(text: "Logger"),
                ],
              ),
            ),
            // TabBarView
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Dashboard Tab
                  dashboardView(),
                  // Logger Tab
                  loggerView(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget dashboardView() {
    return Column(
      children: [
        // RPM Gauge (Large)
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: rpmGauge(),
          ),
        ),
        // AFR & MAP Gauges (Small)
        Expanded(
          flex: 2,
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: afrGauge(),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: mapGauge(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget loggerView() {
    return Column(
      children: [
        // Logger controls
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.grey.shade900,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    isLogging = !isLogging;
                    if (!isLogging) {
                      // Save when stopping
                      saveLogData();
                    }
                  });
                },
                icon: Icon(isLogging ? Icons.stop : Icons.play_arrow),
                label: Text(isLogging ? "Stop Logging" : "Start Logging"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isLogging ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
              ElevatedButton.icon(
                onPressed: logHistory.isEmpty ? null : () {
                  setState(() {
                    logHistory.clear();
                    saveLogData(); // Save empty list
                  });
                },
                icon: const Icon(Icons.delete),
                label: const Text("Clear"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
              Text(
                "${logHistory.length} entries",
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
        // Data table header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          color: Colors.grey.shade800,
          child: const Row(
            children: [
              Expanded(flex: 2, child: Text("Time", style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold))),
              Expanded(child: Text("RPM", style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              Expanded(child: Text("AFR", style: TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              Expanded(child: Text("MAP", style: TextStyle(color: Color(0xFF00BCD4), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
            ],
          ),
        ),
        // Data list
        Expanded(
          child: logHistory.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.data_usage, size: 64, color: Colors.grey.shade700),
                      const SizedBox(height: 16),
                      Text(
                        isLogging ? "Waiting for data..." : "Press 'Start Logging' to begin",
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: logHistory.length,
                  reverse: true,
                  itemBuilder: (context, index) {
                    final log = logHistory[logHistory.length - 1 - index];
                    final time = "${log.timestamp.hour.toString().padLeft(2, '0')}:"
                        "${log.timestamp.minute.toString().padLeft(2, '0')}:"
                        "${log.timestamp.second.toString().padLeft(2, '0')}";
                    
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.grey.shade800, width: 0.5)),
                        color: index % 2 == 0 ? Colors.black : Colors.grey.shade900,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(time, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ),
                          Expanded(
                            child: Text(
                              log.rpm.toInt().toString(),
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              log.afr.toStringAsFixed(1),
                              style: const TextStyle(color: Color(0xFFFFC107), fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              log.map.toInt().toString(),
                              style: const TextStyle(color: Color(0xFF00BCD4), fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget rpmGauge() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(0.5),
            blurRadius: 30,
            spreadRadius: 5,
          ),
        ],
      ),
      child: SfRadialGauge(
        axes: [
          RadialAxis(
            minimum: 0,
            maximum: 13000,
            interval: 1000,
            startAngle: 140,
            endAngle: 40,
            axisLineStyle: AxisLineStyle(
              thickness: 0.15,
              cornerStyle: CornerStyle.bothCurve,
              color: Colors.grey.shade800,
              thicknessUnit: GaugeSizeUnit.factor,
            ),
            majorTickStyle: MajorTickStyle(
              length: 0.15,
              thickness: 2,
              color: const Color(0xFF00E5FF),
              lengthUnit: GaugeSizeUnit.factor,
            ),
            minorTickStyle: MinorTickStyle(
              length: 0.07,
              thickness: 1.5,
              color: const Color(0xFF00B8D4),
              lengthUnit: GaugeSizeUnit.factor,
            ),
            axisLabelStyle: GaugeTextStyle(
              color: const Color(0xFF00E5FF),
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
            ranges: [
              GaugeRange(
                startValue: 0,
                endValue: 6000,
                color: const Color(0xFF00E5FF),
                startWidth: 20,
                endWidth: 20,
              ),
              GaugeRange(
                startValue: 6000,
                endValue: 9000,
                color: const Color(0xFF00B8D4),
                startWidth: 20,
                endWidth: 20,
              ),
              GaugeRange(
                startValue: 9000,
                endValue: 11000,
                color: Colors.orange,
                startWidth: 20,
                endWidth: 20,
              ),
              GaugeRange(
                startValue: 11000,
                endValue: 13000,
                color: const Color(0xFFFF1744),
                startWidth: 20,
                endWidth: 20,
              ),
            ],
            pointers: [
              NeedlePointer(
                value: rpm,
                needleColor: const Color(0xFF00E5FF),
                needleStartWidth: 1,
                needleEndWidth: 5,
                needleLength: 0.7,
                knobStyle: KnobStyle(
                  color: Colors.white,
                  borderColor: const Color(0xFF00E5FF),
                  borderWidth: 0.05,
                  knobRadius: 0.08,
                ),
              ),
            ],
            annotations: [
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      rpm.toInt().toString(),
                      style: const TextStyle(
                        fontSize: 60,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text(
                      "RPM",
                      style: TextStyle(
                        fontSize: 18,
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                angle: 90,
                positionFactor: 0.5,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget afrGauge() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFFFC107), width: 2),
      ),
      child: SfRadialGauge(
        axes: [
          RadialAxis(
            minimum: 10,
            maximum: 20,
            interval: 2,
            startAngle: 180,
            endAngle: 0,
            axisLineStyle: AxisLineStyle(
              thickness: 0.2,
              cornerStyle: CornerStyle.bothCurve,
              color: Colors.grey.shade800,
              thicknessUnit: GaugeSizeUnit.factor,
            ),
            majorTickStyle: const MajorTickStyle(
              length: 0.1,
              thickness: 1.5,
              color: Color(0xFFFFC107),
              lengthUnit: GaugeSizeUnit.factor,
            ),
            minorTickStyle: const MinorTickStyle(
              length: 0.05,
              thickness: 1,
              color: Color(0xFFFFA726),
              lengthUnit: GaugeSizeUnit.factor,
            ),
            axisLabelStyle: const GaugeTextStyle(
              color: Color(0xFFFFC107),
              fontSize: 10,
            ),
            ranges: [
              GaugeRange(
                startValue: 10,
                endValue: 13,
                color: Colors.red.shade700,
                startWidth: 15,
                endWidth: 15,
              ),
              GaugeRange(
                startValue: 13,
                endValue: 15.5,
                color: Colors.green,
                startWidth: 15,
                endWidth: 15,
              ),
              GaugeRange(
                startValue: 15.5,
                endValue: 20,
                color: Colors.red.shade700,
                startWidth: 15,
                endWidth: 15,
              ),
            ],
            pointers: [
              NeedlePointer(
                value: afr,
                needleColor: const Color(0xFFFFC107),
                needleStartWidth: 0.5,
                needleEndWidth: 3,
                needleLength: 0.65,
                knobStyle: const KnobStyle(
                  color: Colors.white,
                  borderColor: Color(0xFFFFC107),
                  borderWidth: 0.03,
                  knobRadius: 0.06,
                ),
              ),
            ],
            annotations: [
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      afr.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 32,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text(
                      "AFR",
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFFFFC107),
                      ),
                    ),
                  ],
                ),
                angle: 90,
                positionFactor: 0.4,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget mapGauge() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF00BCD4), width: 2),
      ),
      child: SfRadialGauge(
        axes: [
          RadialAxis(
            minimum: 0,
            maximum: 250,
            interval: 50,
            startAngle: 180,
            endAngle: 0,
            axisLineStyle: AxisLineStyle(
              thickness: 0.2,
              cornerStyle: CornerStyle.bothCurve,
              color: Colors.grey.shade800,
              thicknessUnit: GaugeSizeUnit.factor,
            ),
            majorTickStyle: const MajorTickStyle(
              length: 0.1,
              thickness: 1.5,
              color: Color(0xFF00BCD4),
              lengthUnit: GaugeSizeUnit.factor,
            ),
            minorTickStyle: const MinorTickStyle(
              length: 0.05,
              thickness: 1,
              color: Color(0xFF26C6DA),
              lengthUnit: GaugeSizeUnit.factor,
            ),
            axisLabelStyle: const GaugeTextStyle(
              color: Color(0xFF00BCD4),
              fontSize: 10,
            ),
            ranges: [
              GaugeRange(
                startValue: 0,
                endValue: 100,
                color: Colors.green.shade700,
                startWidth: 15,
                endWidth: 15,
              ),
              GaugeRange(
                startValue: 100,
                endValue: 180,
                color: Colors.yellow.shade700,
                startWidth: 15,
                endWidth: 15,
              ),
              GaugeRange(
                startValue: 180,
                endValue: 250,
                color: Colors.red,
                startWidth: 15,
                endWidth: 15,
              ),
            ],
            pointers: [
              NeedlePointer(
                value: map,
                needleColor: const Color(0xFF00BCD4),
                needleStartWidth: 0.5,
                needleEndWidth: 3,
                needleLength: 0.65,
                knobStyle: const KnobStyle(
                  color: Colors.white,
                  borderColor: Color(0xFF00BCD4),
                  borderWidth: 0.03,
                  knobRadius: 0.06,
                ),
              ),
            ],
            annotations: [
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      map.toInt().toString(),
                      style: const TextStyle(
                        fontSize: 32,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text(
                      "MAP kPa",
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF00BCD4),
                      ),
                    ),
                  ],
                ),
                angle: 90,
                positionFactor: 0.4,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
