import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/widgets/uploaded_source_map.dart';

// dart:io is NOT available on web — use conditional import
import 'package:navix_app/utils/file_reader_stub.dart'
    if (dart.library.io) 'package:navix_app/utils/file_reader_io.dart';

class AiModuleScreen extends StatefulWidget {
  const AiModuleScreen({super.key});

  @override
  State<AiModuleScreen> createState() => _AiModuleScreenState();
}

class _AiModuleScreenState extends State<AiModuleScreen> {
  String? _uploadError;
  bool _isUploading = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Pick map image file from local device and upload
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _pickAndUploadMap(RobotStateProvider provider) async {
    setState(() {
      _uploadError = null;
      _isUploading = false;
    });

    try {
      // file_picker ^11 uses FilePicker.platform.pickFiles()
      // withData: true is required on web (bytes are not available otherwise)
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,        // ← always request bytes (safe on all platforms)
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) {
        // User cancelled
        return;
      }

      final pickedFile = result.files.single;
      List<int>? fileBytes;
      final String filename = pickedFile.name;

      // 1. Try bytes first (web + desktop when withData:true)
      if (pickedFile.bytes != null && pickedFile.bytes!.isNotEmpty) {
        fileBytes = pickedFile.bytes!;
      }
      // 2. Fallback: read from path on native (iOS / Android / desktop)
      else if (!kIsWeb && pickedFile.path != null) {
        fileBytes = await readFileBytes(pickedFile.path!);
      }

      if (fileBytes == null || fileBytes.isEmpty) {
        setState(() {
          _uploadError = "Could not read file bytes. Please try again.";
        });
        return;
      }

      setState(() { _isUploading = true; });

      if (!mounted) return;
      final success = await provider.uploadOccupancyMap(fileBytes, filename);

      setState(() { _isUploading = false; });

      if (success && mounted) {
        setState(() { _uploadError = null; });
        final numCheckpoints = provider.loadedMaps.firstWhere((m) => m.fileName == filename).checkpoints.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF00FF66)),
                const SizedBox(width: 8),
                Expanded(child: Text("\"$filename\" analyzed successfully — $numCheckpoints checkpoints found!")),
              ],
            ),
            backgroundColor: const Color(0xFF131B26),
            duration: const Duration(seconds: 4),
          ),
        );
      } else if (!success && mounted) {
        setState(() {
          _uploadError = "Map analysis failed. Make sure the image has clear circular waypoints labeled A, B, C...";
        });
      }
    } on Exception catch (e) {
      setState(() {
        _isUploading = false;
        _uploadError = "File picker error: ${e.toString()}";
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Load the pre-generated sample map from the FastAPI backend
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadSampleMap(RobotStateProvider provider) async {
    setState(() { _uploadError = null; });
    provider.setAlert("Loading synthetic occupancy grid map from AI backend...");

    try {
      // Use the backend URL from provider settings (keeps CORS clean)
      final backendUrl = "http://${provider.backendIp}/static/sample_map.png";
      final response = await http.get(
        Uri.parse(backendUrl),
        headers: {"Accept": "image/*"},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final success = await provider.uploadOccupancyMap(
          response.bodyBytes,
          "sample_map.png",
        );
        provider.clearAlert();

        if (success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Sample warehouse map loaded successfully!"),
              backgroundColor: Color(0xFF131B26),
            ),
          );
        } else if (!success) {
          setState(() {
            _uploadError = "Sample map analysis failed. Check backend logs.";
          });
        }
      } else {
        provider.setAlert(
          "Failed to fetch sample map (HTTP ${response.statusCode}). "
          "Ensure the backend is running at ${provider.backendIp}.",
        );
      }
    } catch (e) {
      provider.setAlert("Error downloading sample map: ${e.toString()}");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);
    final bool isLoading = provider.isPlanning || _isUploading;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          const Text(
            "NAVIX AI MAP GRAPH EXTRACTOR",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
          const Text(
            "Upload occupancy grids to compile corridor pathways and waypoint checkpoints",
            style: TextStyle(color: Color(0xFF5A6F8F), fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),

          // Main Layout
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 900;
              return Column(
                children: [
                  isWide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 3, child: _buildMapSection(provider, isLoading)),
                            const SizedBox(width: 24),
                            Expanded(flex: 2, child: _buildControlSection(provider, isLoading)),
                          ],
                        )
                      : Column(
                          children: [
                            _buildMapSection(provider, isLoading, height: 400),
                            const SizedBox(height: 24),
                            _buildControlSection(provider, isLoading),
                          ],
                        ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMapSection(RobotStateProvider provider, bool isLoading, {double height = 500}) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          const UploadedSourceMap(),
          if (isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SpinKitRing(
                      color: Color(0xFF00FFCC),
                      size: 60.0,
                      lineWidth: 4,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "ANALYZING OCCUPANCY GRID...",
                      style: TextStyle(
                        color: Color(0xFF00FFCC),
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isUploading
                          ? "Uploading image to AI backend..."
                          : "Running contour parsing & character templates...",
                      style: const TextStyle(color: Color(0xFF5A6F8F), fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControlSection(RobotStateProvider provider, bool isLoading) {
    return Column(
      children: [
        // ── Action Card ──────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF131B26),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1E2E43), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "MAP IMPORT CONTROLLER",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
              ),
              const Divider(color: Color(0xFF1E2E43), height: 24),
              const Text(
                "Select a binary grid map image (PNG/JPEG). "
                "Corridors should be white, walls black. "
                "Waypoints must be labeled circles (A, B, C...).",
                style: TextStyle(color: Color(0xFF6B7A90), fontSize: 11),
              ),
              const SizedBox(height: 20),

              // ── Upload Custom Map ────────────────────────────────────────
              ElevatedButton.icon(
                onPressed: isLoading ? null : () => _pickAndUploadMap(provider),
                icon: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.black54,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.cloud_upload_outlined, color: Colors.black),
                label: Text(
                  isLoading ? "PROCESSING..." : "UPLOAD CUSTOM MAP",
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 1),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FFCC),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 12),

              // ── Load Sample Map ──────────────────────────────────────────
              OutlinedButton.icon(
                onPressed: isLoading ? null : () => _loadSampleMap(provider),
                icon: const Icon(Icons.factory_outlined, color: Color(0xFFCC00FF)),
                label: const Text(
                  "LOAD SAMPLE WAREHOUSE MAP",
                  style: TextStyle(color: Color(0xFFCC00FF), fontWeight: FontWeight.bold, letterSpacing: 1),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFCC00FF), width: 1.5),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),

              // ── Error Banner ─────────────────────────────────────────────
              if (_uploadError != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3366).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFF3366).withValues(alpha: 0.5), width: 1),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Color(0xFFFF3366), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _uploadError!,
                          style: const TextStyle(color: Color(0xFFFF3366), fontSize: 10),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _uploadError = null),
                        child: const Icon(Icons.close, color: Colors.white38, size: 14),
                      ),
                    ],
                  ),
                ),
              ],

            ],
          ),
        ),
      ],
    );
  }
}
