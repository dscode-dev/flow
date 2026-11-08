import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../experiences/domain/experience.dart';
import 'radar_config.dart';
import 'radar_controller.dart';
import 'radar_model.dart';

const _source = 'flow-radar';
const _icons = <String, IconData>{
  'music': Icons.music_note,
  'party': Icons.celebration,
  'culture': Icons.theater_comedy,
  'sport': Icons.sports_soccer,
  'gastronomy': Icons.restaurant,
  'nature': Icons.park,
  'tech': Icons.computer,
  'education': Icons.school,
  'community': Icons.groups,
  'other': Icons.place,
};
Map<String, dynamic> radarGeoJson(List<RadarMarker> items) => {
  'type': 'FeatureCollection',
  'features': [
    for (var i = 0; i < items.length; i++)
      {
        'type': 'Feature',
        'id': i,
        'geometry': {
          'type': 'Point',
          'coordinates': [items[i].point.longitude, items[i].point.latitude],
        },
        'properties': {
          'experience_id': items[i].id,
          'category_id': items[i].categoryId,
          'phase': items[i].phase,
          'icon':
              'flow-${_icons.containsKey(items[i].categoryId) ? items[i].categoryId : 'other'}',
        },
      },
  ],
};
// Native SDK is the rendering boundary; widget tests replace this factory only.
typedef RadarMapBuilder = Widget Function(
  RadarController controller,
  RadarConfig config,
  ValueChanged<String> onSelect,
);
final radarMapBuilderProvider = Provider<RadarMapBuilder>(
  (ref) =>
      (controller, config, onSelect) =>
          RadarMap(controller: controller, config: config, onSelect: onSelect),
);

class RadarMap extends StatefulWidget {
  const RadarMap({
    super.key,
    required this.controller,
    required this.config,
    required this.onSelect,
  });
  final RadarController controller;
  final RadarConfig config;
  final ValueChanged<String> onSelect;
  @override
  State<RadarMap> createState() => _RadarMapState();
}

class _RadarMapState extends State<RadarMap> {
  final _viewport = ViewportController();
  MapboxMap? _map;
  int _styleGeneration = 0, _cameraGeneration = 0;
  bool _ready = false, _syncing = false, _pending = false;
  bool _sourceFailure = false;
  String? _style, _lastData, _lastSelection;
  Stopwatch? _frame;
  @override
  void initState() {
    super.initState();
    MapboxOptions.setAccessToken(widget.config.token);
    widget.controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark =
        widget.config.theme == 'dark' ||
        (widget.config.theme == 'system' &&
            Theme.of(context).brightness == Brightness.dark);
    final next = dark ? widget.config.darkStyle : widget.config.lightStyle;
    if (_style != null && next != _style) {
      _ready = false;
      _sourceFailure = false;
      _styleGeneration++;
      final camera = widget.controller.camera;
      if (camera != null) {
        _viewport.moveTo(
          CameraViewportState(
            center: Point(
              coordinates: Position(
                camera.center.longitude,
                camera.center.latitude,
              ),
            ),
            zoom: camera.zoom,
          ),
          transition: null,
        );
      }
      _map?.loadStyleURI(next).catchError((Object _) {
        if (mounted) widget.controller.mapFailed();
      });
    }
    _style = next;
  }

  int _lastCommand = 0;
  void _changed() {
    _sync();
    final c = widget.controller.camera;
    if (c != null && widget.controller.cameraCommand != _lastCommand) {
      _lastCommand = widget.controller.cameraCommand;
      _viewport.moveTo(
        CameraViewportState(
          center: Point(
            coordinates: Position(c.center.longitude, c.center.latitude),
          ),
          zoom: c.zoom,
        ),
        transition: null,
      );
    }
  }

  Future<void> _created(MapboxMap map) async {
    _map = map;
    try {
      await map.logo.updateSettings(
        LogoSettings(
          enabled: true,
          position: OrnamentPosition.TOP_LEFT,
          marginLeft: 8,
          marginTop: 8,
        ),
      );
      await map.attribution.updateSettings(
        AttributionSettings(
          enabled: true,
          clickable: true,
          position: OrnamentPosition.TOP_RIGHT,
          marginRight: 8,
          marginTop: 8,
        ),
      );
      await map.location.updateSettings(
        LocationComponentSettings(enabled: false, pulsingEnabled: false),
      );
      await map.setBounds(
        CameraBoundsOptions(minZoom: 0, maxZoom: 22, maxPitch: 0),
      );
      map.addInteraction(
        TapInteraction(FeaturesetDescriptor(layerId: 'flow-clusters'), (
          feature,
          context,
        ) {
          final c = widget.controller.camera;
          if (c == null) return;
          _viewport.moveTo(
            CameraViewportState(
              center: context.point,
              zoom: (c.zoom + 2).clamp(0, 22),
            ),
            transition: null,
          );
        }),
        interactionID: 'flow-cluster-tap',
      );
      map.addInteraction(
        TapInteraction(FeaturesetDescriptor(layerId: 'flow-pins'), (
          feature,
          context,
        ) {
          final id = feature.properties['experience_id'];
          if (id is String &&
              widget.controller.value.document?.items.any((m) => m.id == id) ==
                  true) {
            widget.onSelect(id);
          }
        }),
        interactionID: 'flow-pin-tap',
      );
    } catch (_) {
      if (mounted) widget.controller.mapFailed();
    }
  }

  Future<void> _styleLoaded() async {
    final map = _map;
    if (map == null) return;
    final generation = ++_styleGeneration;
    _ready = false;
    _sourceFailure = false;
    try {
      await map.setStyleTransition(TransitionOptions(duration: 0, delay: 0));
      for (final entry in _icons.entries) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final painter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(entry.value.codePoint),
            style: TextStyle(
              fontFamily: entry.value.fontFamily,
              fontSize: 40,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          Offset((64 - painter.width) / 2, (64 - painter.height) / 2),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 64);
        picture.dispose();
        final pixels = await StyleImage.fromImage(image);
        image.dispose();
        if (!mounted || generation != _styleGeneration) return;
        await map.addImage('flow-${entry.key}', 2, pixels);
      }
      if (!mounted || generation != _styleGeneration) return;
      await map.addStyleSource(
        _source,
        jsonEncode({
          'type': 'geojson',
          'data': radarGeoJson([]),
          'cluster': true,
          'clusterRadius': 48,
          'clusterMaxZoom': 16,
        }),
      );
      final layers = <Map<String, dynamic>>[
        {
          'id': 'flow-clusters',
          'type': 'circle',
          'source': _source,
          'filter': ['has', 'point_count'],
          'paint': {
            'circle-color': '#2556D8',
            'circle-radius': [
              'step',
              ['get', 'point_count'],
              18,
              20,
              23,
              75,
              28,
            ],
            'circle-stroke-color': '#FFFFFF',
            'circle-stroke-width': 2,
          },
        },
        {
          'id': 'flow-cluster-count',
          'type': 'symbol',
          'source': _source,
          'filter': ['has', 'point_count'],
          'layout': {
            'text-field': [
              'to-string',
              ['get', 'point_count'],
            ],
            'text-size': 13,
          },
          'paint': {'text-color': '#FFFFFF'},
        },
        {
          'id': 'flow-pins',
          'type': 'circle',
          'source': _source,
          'filter': [
            '!',
            ['has', 'point_count'],
          ],
          'paint': {
            'circle-radius': [
              'case',
              [
                '==',
                ['get', 'phase'],
                'LIVE',
              ],
              15,
              12,
            ],
            'circle-color': [
              'match',
              ['get', 'category_id'],
              'music',
              '#7445C8',
              'party',
              '#C53568',
              'culture',
              '#8541A8',
              'sport',
              '#18734F',
              'gastronomy',
              '#996100',
              'nature',
              '#147746',
              'tech',
              '#2556D8',
              'education',
              '#365DA8',
              'community',
              '#6552AE',
              '#2556D8',
            ],
            'circle-stroke-color': [
              'case',
              [
                '==',
                ['get', 'phase'],
                'LIVE',
              ],
              '#C53568',
              '#FFFFFF',
            ],
            'circle-stroke-width': 2,
          },
        },
        {
          'id': 'flow-icons',
          'type': 'symbol',
          'source': _source,
          'filter': [
            '!',
            ['has', 'point_count'],
          ],
          'layout': {
            'icon-image': ['get', 'icon'],
            'icon-size': 0.65,
            'icon-allow-overlap': true,
            'icon-ignore-placement': true,
          },
        },
        {
          'id': 'flow-selection',
          'type': 'circle',
          'source': _source,
          'filter': [
            '==',
            ['get', 'experience_id'],
            '',
          ],
          'paint': {
            'circle-radius': 20,
            'circle-opacity': 0,
            'circle-stroke-width': 3,
            'circle-stroke-color': '#C53568',
          },
        },
      ];
      for (final layer in layers) {
        if (!mounted || generation != _styleGeneration) return;
        await map.addStyleLayer(jsonEncode(layer), null);
      }
      if (!mounted || generation != _styleGeneration) return;
      _ready = true;
      _lastData = null;
      _lastSelection = null;
      await _sync();
      await _idle();
    } catch (_) {
      if (mounted && generation == _styleGeneration) {
        _ready = false;
        _sourceFailure = true;
        widget.controller.mapFailed();
      }
    }
  }

  Future<void> _sync() async {
    if (!_ready || _map == null || !mounted) return;
    if (_syncing) {
      _pending = true;
      return;
    }
    _syncing = true;
    final generation = _styleGeneration;
    try {
      do {
        _pending = false;
        final data = jsonEncode(
          radarGeoJson(widget.controller.value.document?.items ?? []),
        );
        if (data != _lastData) {
          await _map!.setStyleSourceProperty(_source, 'data', data);
          if (!mounted || generation != _styleGeneration) return;
          _lastData = data;
          _frame = widget.controller.value.document?.items.isNotEmpty == true
              ? (Stopwatch()..start())
              : null;
        }
        final selected = widget.controller.selectedId ?? '';
        if (selected != _lastSelection) {
          await _map!.setStyleLayerProperty('flow-selection', 'filter', [
            '==',
            ['get', 'experience_id'],
            selected,
          ]);
          if (!mounted || generation != _styleGeneration) return;
          _lastSelection = selected;
        }
      } while (_pending && mounted && _ready && generation == _styleGeneration);
    } catch (_) {
      if (mounted && generation == _styleGeneration) {
        _ready = false;
        _sourceFailure = true;
        widget.controller.mapFailed();
      }
    } finally {
      _syncing = false;
      if (_pending && mounted && _ready) {
        _pending = false;
        _sync();
      }
    }
  }

  Future<void> _idle() async {
    if (!mounted || !_ready || _map == null) return;
    final generation = ++_cameraGeneration;
    try {
      final c = await _map!.getCameraState();
      final b = await _map!.coordinateBoundsForCameraUnwrapped(
        CameraOptions(
          center: c.center,
          zoom: c.zoom,
          bearing: c.bearing,
          pitch: c.pitch,
        ),
      );
      if (!mounted || generation != _cameraGeneration) return;
      final w = b.southwest.coordinates.lng.toDouble(),
          e = b.northeast.coordinates.lng.toDouble();
      double wrap(double x) => ((x + 180) % 360) - 180;
      final span = e - w;
      final bounds = RadarBounds(
        span >= 360 ? -180 : wrap(w),
        b.southwest.coordinates.lat.toDouble().clamp(-85.051129, 85.051129),
        span >= 360 ? 180 : wrap(e),
        b.northeast.coordinates.lat.toDouble().clamp(-85.051129, 85.051129),
      );
      widget.controller.viewport(
        bounds,
        RadarCamera(
          GeoPoint(
            c.center.coordinates.lat.toDouble(),
            wrap(c.center.coordinates.lng.toDouble()),
          ),
          c.zoom,
        ),
      );
    } catch (_) {
      if (mounted) widget.controller.mapFailed();
    }
  }

  @override
  void dispose() {
    _styleGeneration++;
    _cameraGeneration++;
    widget.controller.removeListener(_changed);
    _map?.removeInteraction('flow-cluster-tap');
    _map?.removeInteraction('flow-pin-tap');
    _viewport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.controller.camera ?? widget.config.initial;
    return MapWidget(
      key: const ValueKey('flow-radar-native-map'),
      styleUri: _style ?? widget.config.lightStyle,
      viewportController: _viewport,
      viewport: CameraViewportState(
        center: Point(
          coordinates: Position(
            camera.center.longitude,
            camera.center.latitude,
          ),
        ),
        zoom: camera.zoom,
        bearing: 0,
        pitch: 0,
      ),
      onMapCreated: _created,
      onStyleLoadedListener: (_) => _styleLoaded(),
      onMapLoadedListener: (_) {
        if (!_sourceFailure) widget.controller.mapReady();
      },
      onCameraChangeListener: (_) {
        _cameraGeneration++;
        widget.controller.moving();
      },
      onMapIdleListener: (_) => _idle(),
      onMapLoadErrorListener: (_) => widget.controller.mapFailed(),
      onRenderFrameFinishedListener: (event) {
        if (event.renderMode == RenderMode.FULL && _frame != null) {
          widget.controller.metrics.pinsFrameMs = _frame!.elapsedMilliseconds;
          _frame = null;
        }
      },
    );
  }
}
