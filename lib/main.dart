import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Python Sidecar Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ImageProcessorPage(),
    );
  }
}

class ImageProcessorPage extends StatefulWidget {
  const ImageProcessorPage({super.key});

  @override
  State<ImageProcessorPage> createState() => _ImageProcessorPageState();
}

class _ImageProcessorPageState extends State<ImageProcessorPage> {
  File? _originalImage;
  File? _processedImage;
  bool _isProcessing = false;
  String _statusMessage = 'Select an image to get started';
  List<String> _processLogs = [];

  // Cache the Python executable path to avoid repeated lookups
  String? _cachedPythonPath;

  // Limit log entries to prevent unbounded memory growth
  static const int _maxLogEntries = 50;

  @override
  void dispose() {
    _cleanupTempFiles();
    super.dispose();
  }

  /// Clean up temporary processed images to free memory
  Future<void> _cleanupTempFiles() async {
    try {
      if (_processedImage != null && await _processedImage!.exists()) {
        await _processedImage!.delete();
      }
    } catch (e) {
      // Silently handle cleanup errors
      debugPrint('Error cleaning up temp files: $e');
    }
  }

  /// Dynamically locate the Python executable in the app's bundle (with caching)
  Future<String> _getPythonExecutablePath() async {
    // Return cached path if available
    if (_cachedPythonPath != null) {
      return _cachedPythonPath!;
    }

    // Determine the executable name based on platform
    String execName = Platform.isWindows
        ? 'image_processor.exe'
        : 'image_processor';

    String? foundPath;

    // In debug mode, assets are in the project's asset folder
    // In release mode, they're bundled with the app
    if (Platform.isWindows) {
      // Windows Release: executable is in data/flutter_assets/assets/python_processor/
      final exePath = path.join(
        path.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'python_processor',
        execName,
      );

      if (await File(exePath).exists()) {
        foundPath = exePath;
      } else {
        // Fallback for debug mode
        final debugPath = path.join(
          Directory.current.path,
          'assets',
          'python_processor',
          execName,
        );

        if (await File(debugPath).exists()) {
          foundPath = debugPath;
        }
      }
    } else if (Platform.isMacOS) {
      // macOS: executable is in Contents/Frameworks/App.framework/Resources/flutter_assets/assets/python_processor/
      final exePath = path.join(
        path.dirname(Platform.resolvedExecutable),
        '..',
        'Frameworks',
        'App.framework',
        'Resources',
        'flutter_assets',
        'assets',
        'python_processor',
        execName,
      );

      if (await File(exePath).exists()) {
        foundPath = exePath;
      } else {
        // Fallback for debug mode
        final debugPath = path.join(
          Directory.current.path,
          'assets',
          'python_processor',
          execName,
        );

        if (await File(debugPath).exists()) {
          foundPath = debugPath;
        }
      }
    }

    if (foundPath == null) {
      throw Exception(
          'Python executable not found. Expected at one of the standard bundle locations.\n'
              'Make sure "$execName" is in assets/python_processor/ and listed in pubspec.yaml'
      );
    }

    // Cache the path for future use
    _cachedPythonPath = foundPath;
    return foundPath;
  }

  /// Pick an image file using file_picker
  Future<void> _pickImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        // Clean up previous processed image before loading new one
        await _cleanupTempFiles();

        setState(() {
          _originalImage = File(result.files.single.path!);
          _processedImage = null;
          _statusMessage = 'Image selected. Ready to process.';
          _processLogs.clear();
        });
      }
    } catch (e) {
      _showError('Failed to pick image: $e');
    }
  }

  /// Process the image using the Python sidecar
  Future<void> _processImage() async {
    if (_originalImage == null) {
      _showError('Please select an image first');
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Locating Python executable...';
      _processLogs.clear();
    });

    try {
      // Clean up any previous processed image
      await _cleanupTempFiles();

      // 1. Locate the Python executable (uses cache if available)
      final execPath = await _getPythonExecutablePath();
      _addLog('✓ Found Python executable: $execPath');

      // 2. Verify the executable exists and is executable
      final execFile = File(execPath);
      if (!await execFile.exists()) {
        throw Exception('Executable not found at: $execPath');
      }

      // On Unix systems, ensure executable permissions
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', execPath]);
        _addLog('✓ Set executable permissions');
      }

      // 3. Create temporary output path
      final tempDir = await getTemporaryDirectory();
      final outputPath = path.join(
        tempDir.path,
        'processed_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      _addLog('✓ Output path: $outputPath');

      // 4. Execute Python process asynchronously
      setState(() => _statusMessage = 'Processing image...');

      final result = await Process.run(
        execPath,
        [_originalImage!.path, outputPath],
      );

      // 5. Handle exit codes
      if (result.exitCode != 0) {
        // Parse error from stderr
        final errorMsg = result.stderr.toString();
        Map<String, dynamic>? errorJson;

        try {
          errorJson = jsonDecode(errorMsg);
        } catch (_) {
          // If stderr isn't JSON, use it as-is
        }

        final displayError = errorJson != null
            ? '${errorJson['error_type']}: ${errorJson['message']}'
            : errorMsg;

        throw Exception('Process failed (exit code ${result.exitCode}): $displayError');
      }

      // 6. Parse stdout logs (efficiently)
      final stdout = result.stdout.toString();
      final lines = stdout.split('\n').where((line) => line.trim().isNotEmpty);

      for (final line in lines) {
        try {
          final log = jsonDecode(line) as Map<String, dynamic>;
          _addLog('${log['status'].toString().toUpperCase()}: ${log['message']}');

          if (log['status'] == 'success' && log['details'] != null) {
            final details = log['details'] as Map<String, dynamic>;
            _addLog('  → Dimensions: ${details['dimensions']}');
            _addLog('  → File size: ${details['file_size_mb']} MB');
          }
        } catch (_) {
          _addLog(line);
        }
      }

      // 7. Verify output file was created
      final processedFile = File(outputPath);
      if (!await processedFile.exists()) {
        throw Exception('Output file was not created');
      }

      // 8. Update UI with result
      setState(() {
        _processedImage = processedFile;
        _statusMessage = 'Processing complete!';
        _isProcessing = false;
      });

    } catch (e) {
      _showError(e.toString());
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _addLog(String message) {
    setState(() {
      _processLogs.add(message);

      // Limit log entries to prevent memory growth
      if (_processLogs.length > _maxLogEntries) {
        _processLogs.removeRange(0, _processLogs.length - _maxLogEntries);
      }

      _statusMessage = message;
    });
  }

  void _showError(String message) {
    setState(() {
      _statusMessage = 'Error: $message';
      _processLogs.add('❌ $message');

      // Apply log limit here too
      if (_processLogs.length > _maxLogEntries) {
        _processLogs.removeRange(0, _processLogs.length - _maxLogEntries);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Image Processor with Python Sidecar'),
        elevation: 2,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Control buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _pickImage,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Select Image'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: (_originalImage != null && !_isProcessing)
                      ? _processImage
                      : null,
                  icon: _isProcessing
                      ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                      : const Icon(Icons.auto_fix_high),
                  label: Text(_isProcessing ? 'Processing...' : 'Process Image'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Status message
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _isProcessing ? Icons.hourglass_empty : Icons.info_outline,
                    color: Colors.blue.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMessage,
                      style: TextStyle(
                        color: Colors.blue.shade900,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Image comparison view
            Expanded(
              child: Row(
                children: [
                  // Original image
                  Expanded(
                    child: _buildImageContainer(
                      'Original',
                      _originalImage,
                      Colors.grey.shade200,
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Processed image
                  Expanded(
                    child: _buildImageContainer(
                      'Processed',
                      _processedImage,
                      Colors.green.shade50,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Process logs
            Container(
              height: 120,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _processLogs.isEmpty
                  ? const Center(
                child: Text(
                  'Logs will appear here',
                  style: TextStyle(
                    color: Colors.grey,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              )
                  : ListView.builder(
                itemCount: _processLogs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      _processLogs[index],
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageContainer(String label, File? imageFile, Color bgColor) {
    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: imageFile != null
                ? ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
              child: Image.file(
                imageFile,
                fit: BoxFit.contain,
                // Important: Use cacheWidth/cacheHeight to reduce memory for large images
                cacheWidth: 800, // Adjust based on your UI needs
                errorBuilder: (context, error, stackTrace) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.red.shade300,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Failed to load image',
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            )
                : Center(
              child: Icon(
                Icons.image_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}