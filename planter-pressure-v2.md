# Clinical Plantar Analysis System - BLoC Architecture

## System Overview
Windows-first Flutter Desktop app for clinical foot pressure analysis. Target: Low-end clinic PCs (i3, 8GB RAM). Offline-first with optional cloud sync.

**Stack:** Flutter Desktop + Python 3.11 (embedded) + SQLite + Optional Node.js backend  
**Integration:** File-path based (Flutter → Python via CLI args, Python → JSON/PNG output)

---

## Core Principle: Separation of Concerns

### Flutter (UI + Orchestration + Data)
- UI rendering, navigation, state management (BLoC)
- Patient/session CRUD (SQLite)
- Image capture (save to disk only, NO pixel processing)
- Python process lifecycle management
- Result visualization, PDF reports

### Python (Analytics Only)
- ALL image/video processing, ML inference
- Pressure map generation, heatmaps
- Region segmentation (heel, midfoot, forefoot, toes)
- Output: JSON metrics + processed PNG files

### Integration Contract
```
Flutter → Python: File paths as CLI arguments
Python → Flutter: JSON + PNG written to disk
NO in-memory communication, NO FFI, NO HTTP
```

---

## BLoC State Management

### BLoC Structure
```
lib/
  ├── blocs/
  │   ├── patient/ (PatientBloc, PatientEvent, PatientState)
  │   ├── session/ (SessionBloc, SessionEvent, SessionState)
  │   ├── analysis/ (AnalysisBloc, AnalysisEvent, AnalysisState)
  │   ├── capture/ (CaptureBloc, CaptureEvent, CaptureState)
  │   └── sync/ (SyncBloc, SyncEvent, SyncState)
  ├── repositories/ (PatientRepo, AnalysisRepo, FileRepo)
  ├── services/ (PythonService, CameraService, DatabaseService)
  └── models/ (Patient, Session, AnalysisResult, etc.)
```

### Key BLoCs

**PatientBloc**
- Events: `LoadPatients`, `CreatePatient`, `UpdatePatient`, `DeletePatient`
- States: `PatientInitial`, `PatientLoading`, `PatientLoaded`, `PatientError`

**AnalysisBloc**
- Events: `StartAnalysis`, `AnalysisCompleted`, `AnalysisFailed`, `RetryAnalysis`
- States: `AnalysisIdle`, `AnalysisProcessing`, `AnalysisSuccess`, `AnalysisError`
- Emits progress updates during Python execution

**CaptureBloc**
- Events: `InitializeCamera`, `CaptureImage`, `CaptureVideo`, `DisposeCamera`
- States: `CameraUninitialized`, `CameraReady`, `CapturingImage`, `CaptureSuccess`

### State Management Rules
- **Single BLoC per feature** (PatientBloc, AnalysisBloc, etc.)
- **Repository pattern** for data access (BLoC → Repo → DataSource)
- **Close BLoCs** on screen disposal to prevent memory leaks
- **StreamSubscription** for Python process output
- **Equatable** for state comparison (avoid unnecessary rebuilds)

---

## Data Flow Example: Image Analysis

```
1. User taps "Analyze" → CaptureBloc.add(CaptureImage())
2. CaptureBloc saves raw PNG to disk → emits CaptureSuccess(imagePath)
3. AnalysisBloc.add(StartAnalysis(imagePath))
4. AnalysisBloc → PythonService.runAnalysis(inputPath, outputDir)
5. PythonService spawns process: python analyze.py --input input.png --output output/
6. Python processes (5-15s), writes result.json + heatmap.png, exits
7. PythonService reads result.json → emits AnalysisSuccess(AnalysisResult)
8. UI rebuilds via BlocBuilder<AnalysisBloc, AnalysisState>
9. AnalysisRepo saves result to SQLite
```

---

## Memory Management (CRITICAL)

### Target Budgets
- Idle: <150 MB
- Analysis: <800 MB total (200 MB Flutter + 600 MB Python)
- Viewing results: <250 MB
- Stress (10 results): <500 MB hard limit

### Rules
1. **Image Cache:** Max 200 MB, clear on screen disposal
2. **Downsampling:** Always use `cacheWidth`/`cacheHeight` in Image.file()
3. **Thumbnails:** 200x300 for lists, full-res on-demand
4. **Disposal:** Close BLoCs, cancel streams, evict images in dispose()
5. **No Full-Res in Memory:** Store file paths, load images as needed

### Memory Leak Prevention
```dart
@override
void dispose() {
  _patientBloc.close();
  _imageCache.clear();
  _subscription?.cancel();
  FileImage(File(imagePath)).evict();
  super.dispose();
}
```

---

## Python Integration

### Execution
```dart
final pythonExe = path.join(appDir, 'python_runtime', 'python.exe');
final process = await Process.start(pythonExe, [
  'analyze.py',
  '--input', inputPath,
  '--output', outputDir,
  '--mode', 'static',
]);

final exitCode = await process.exitCode.timeout(Duration(seconds: 120));
if (exitCode != 0) throw PythonExecutionException();

final json = File('$outputDir/result.json').readAsStringSync();
return AnalysisResult.fromJson(jsonDecode(json));
```

### Output Schema (result.json)
```json
{
  "status": "success",
  "processing_time_seconds": 8.3,
  "metrics": {
    "total_force_n": 650.3,
    "average_pressure_kpa": 35.1,
    "regions": {
      "heel": {"peak_pressure_kpa": 250.5, "area_cm2": 45.2},
      "midfoot": {...},
      "forefoot": {...},
      "toes": {...}
    }
  },
  "warnings": ["High pressure in heel (>200 kPa)"]
}
```

### Error Handling
- **Timeout:** 120s, kill process with SIGTERM
- **Non-zero exit:** Read stderr, emit `AnalysisFailed(errorMessage)`
- **Missing output:** Emit `AnalysisFailed("No output file")`
- **Retry:** Max 2 retries with 2s delay
- Display user-friendly error + retry button

---

## Image/Video Rules

### Capture
- **Preview:** 640x480 (live feed)
- **Standard:** 1920x1080 (default)
- **High-Res:** 3840x2160 (research)
- **Format:** PNG (lossless) for raw captures
- **Video:** 30s max, 720p, 30 FPS, H.264

### CRITICAL: Flutter NEVER Processes Pixels
- Flutter = capture + display only
- Python = ALL pixel manipulation, heatmaps, ML
- **Why:** Performance (Dart 10-100x slower), Memory (heap exhaustion), Accuracy (validated libraries), Regulatory (separate UI from analytics)

---

## Hard Rules

### Flutter MUST NEVER
- Process pixels (RGB manipulation)
- Calculate pressure values
- Generate heatmaps or run ML models
- Block UI thread with long operations
- Store full-res images in memory
- Ignore BLoC disposal

### Python MUST NEVER
- Manage database (Flutter owns SQLite)
- Display UI (headless operation)
- Maintain long-running processes (run once, exit)
- Communicate via HTTP (file-based only)
- Store state across invocations (stateless)
- Modify input files (read-only)

---

## Database Schema (SQLite)
```sql
patients (id, name, age, gender, medical_history)
sessions (id, patient_id, session_date, notes)
measurements (id, session_id, image_path, video_path)
results (id, measurement_id, json_data, heatmap_path, created_at)
reports (id, session_id, pdf_path, generated_at)
sync_queue (id, operation, data, synced)
```

---

## Performance Targets

### Speed
- Cold start: <3s
- Warm start: <1s
- Analysis: 5-15s (Python processing)
- Navigation: 60 FPS, no frame drops

### CPU
- Idle: <5%
- Analysis: <80% (1 core, Python only)

### Acceptance Tests
1. **Rapid Navigation:** 10 screens in 30s, no drops, memory <250 MB
2. **50 Analyses:** No memory leaks, returns to baseline
3. **10 Result Comparison:** Load in 5s, memory <400 MB
4. **4-Hour Session:** Stable <200 MB idle

---

## Error Recovery

| Error | Action | Max Recovery |
|-------|--------|--------------|
| Python crash | Retry button, log error | 5s |
| Out of memory | Clear cache, trigger GC, warn user | 10s |
| DB corruption | Auto-repair, restore backup | 30s |
| Disk full | Check space before save, suggest cleanup | - |

---

## Scalability

### Adding New Models
1. Add Python script (e.g., `analyze_gait.py`)
2. Update AnalysisMode enum
3. Route in PythonService
4. Add UI option
5. Extend database schema

### Cloud Sync
- `sync_queue` table tracks pending changes
- Background BLoC syncs when online
- Last-write-wins conflict resolution
- All operations work offline

---

## Key Decisions

1. **File-Path Integration:** Simple, debuggable, fault-tolerant, regulatory-compliant
2. **Embedded Python:** No external dependencies, consistent environment
3. **Offline-First:** Full functionality without internet
4. **BLoC Pattern:** Predictable state, testable, separation of concerns
5. **SQLite:** Lightweight, reliable, no server
6. **Process Isolation:** Python memory doesn't affect Flutter heap
7. **Stateless Python:** Run once, exit cleanly

---

## Regulatory Prep (IEC 62304, FDA 21 CFR Part 11)
- Software design docs (this document)
- Risk analysis (FMEA)
- Unit/integration/system tests
- Audit logs (all user actions)
- Data encryption at rest
- User auth + RBAC
- Algorithm validation (accuracy metrics, clinical studies)
- Change control (Git, changelog, regression tests)