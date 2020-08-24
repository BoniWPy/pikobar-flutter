import 'dart:convert';
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pikobar_flutter/components/RoundedButton.dart';
import 'package:pikobar_flutter/configs/SharedPreferences/Location.dart';
import 'package:pikobar_flutter/constants/Analytics.dart';
import 'package:pikobar_flutter/constants/Colors.dart';
import 'package:pikobar_flutter/constants/Dictionary.dart';
import 'package:pikobar_flutter/constants/Dimens.dart';
import 'package:pikobar_flutter/constants/FontsFamily.dart';
import 'package:pikobar_flutter/constants/UrlThirdParty.dart';
import 'package:pikobar_flutter/constants/collections.dart';
import 'package:pikobar_flutter/environment/Environment.dart';
import 'package:pikobar_flutter/models/LocationModel.dart';
import 'package:pikobar_flutter/repositories/AuthRepository.dart';
import 'package:pikobar_flutter/repositories/LocationsRepository.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
as bg;
import 'package:pikobar_flutter/utilities/NotificationHelper.dart';
import 'AnalyticsHelper.dart';

class LocationService {
  static Future<void> initializeBackgroundLocation(BuildContext context) async {
    Map<String, dynamic> firebaseUser = await _firebaseUser();
    if (firebaseUser['isMonitoredUser']) {
      if (await Permission.locationAlways.status.isGranted &&
          await Permission.activityRecognition.status.isGranted) {
        await _configureBackgroundLocation(userAddressCoordinate: firebaseUser['location']);
        await actionSendLocation();
      } else {
        showModalBottomSheet(
            context: context,
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8.0),
                topRight: Radius.circular(8.0),
              ),
            ),
            isDismissible: false,
            builder: (context) {
              return Container(
                margin: EdgeInsets.all(Dimens.padding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Image.asset(
                      '${Environment.imageAssets}permission_location.png',
                      fit: BoxFit.fitWidth,
                    ),
                    SizedBox(height: Dimens.padding),
                    Text(
                      Dictionary.permissionLocationGeneral,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontFamily: FontsFamily.lato,
                          fontSize: 14.0,
                          fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8.0),
                    Text(
                      Dictionary.permissionLocationAgreement,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontFamily: FontsFamily.lato,
                          fontSize: 12.0,
                          color: Colors.grey[600]),
                    ),
                    SizedBox(height: 24.0),
                    Row(
                      children: <Widget>[
                        Expanded(
                            child: RoundedButton(
                                title: Dictionary.later,
                                textStyle: TextStyle(
                                    fontFamily: FontsFamily.lato,
                                    fontSize: 12.0,
                                    fontWeight: FontWeight.bold,
                                    color: ColorBase.green),
                                color: Colors.white,
                                borderSide: BorderSide(color: ColorBase.green),
                                elevation: 0.0,
                                onPressed: () {
                                  AnalyticsHelper.setLogEvent(
                                      Analytics.permissionDismissLocation);
                                  Navigator.of(context).pop();
                                })),
                        SizedBox(width: Dimens.padding),
                        Expanded(
                            child: RoundedButton(
                                title: Dictionary.agree,
                                textStyle: TextStyle(
                                    fontFamily: FontsFamily.lato,
                                    fontSize: 12.0,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white),
                                color: ColorBase.green,
                                elevation: 0.0,
                                onPressed: () async {
                                  Navigator.of(context).pop();
                                  if (await Permission.locationAlways.status
                                      .isPermanentlyDenied &&
                                      await Permission.locationAlways.status
                                          .isPermanentlyDenied) {
                                    Platform.isAndroid
                                        ? await AppSettings.openAppSettings()
                                        : await AppSettings
                                        .openLocationSettings();
                                  } else {
                                    [
                                      Permission.locationAlways,
                                      Permission.activityRecognition,
                                    ].request().then((status) {
                                      _onStatusRequested(context, status, userAddressCoordinate: firebaseUser['location']);
                                    });
                                  }
                                }))
                      ],
                    )
                  ],
                ),
              );
            });
      }
    } else {
      await stopBackgroundLocation();
    }
  }

  // Old Method
  static Future<void> actionSendLocation() async {
    var permissionService = Permission.locationAlways;

    if (await permissionService.isGranted) {
      int oldTime =
      await LocationSharedPreference.getLastLocationRecordingTime();

      if (oldTime == null) {
        oldTime =
            DateTime
                .now()
                .add(Duration(minutes: -6))
                .millisecondsSinceEpoch;
        await LocationSharedPreference.setLastLocationRecordingTime(oldTime);
      }

      int minutes = DateTime
          .now()
          .difference(DateTime.fromMillisecondsSinceEpoch(oldTime))
          .inMinutes;
      Position position = await Geolocator()
          .getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      if (position != null && position.latitude != null) {
        if (minutes >= 5) {
          int currentMillis = DateTime
              .now()
              .millisecondsSinceEpoch;

          LocationModel data = LocationModel(
              id: currentMillis.toString(),
              latitude: position.latitude,
              longitude: position.longitude,
              timestamp: currentMillis);

          await LocationsRepository().saveLocationToFirestore(data);

          // This call after all process done (Moved to LocationsRepository)
          /*await LocationSharedPreference.setLastLocationRecordingTime(
            currentMillis);*/
        }
      }
    }
  }

  // New Method
  static Future<void> _configureBackgroundLocation({GeoPoint userAddressCoordinate}) async {
    if (await Permission.locationAlways.status.isGranted &&
        await Permission.activityRecognition.status.isGranted) {
      String locationTemplate = '{'
          '"latitude":<%= latitude %>, '
          '"longitude":<%= longitude %>, '
          '"speed":<%= speed %>, '
          '"activity":"<%= activity.type %>", '
          '"battery":{"isCharging":<%= battery.is_charging %>, '
          '"level":<%= battery.level %>}, '
          '"timestamp":"<%= timestamp %>"'
          '}';

      // 1.  Listen to events.
      bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError);
      bg.BackgroundGeolocation.onGeofence(_onGeofence);
      bg.BackgroundGeolocation.onMotionChange(_onMotionChange);
      bg.BackgroundGeolocation.onActivityChange(_onActivityChange);
      bg.BackgroundGeolocation.onProviderChange(_onProviderChange);
      bg.BackgroundGeolocation.onConnectivityChange(_onConnectivityChange);
      bg.BackgroundGeolocation.onHttp(_onHttp);

      // 2.  Get the user token
      String userId = await AuthRepository().getToken();

      // 3. Remove all current set geofences and Add a new geofence.
      bg.BackgroundGeolocation.removeGeofences().then((bool success) {
        print('[removeGeofences] all geofences have been destroyed');

        if (userAddressCoordinate != null) {
          bg.BackgroundGeolocation.addGeofence(bg.Geofence(
              identifier: "DANGER_ZONE",
              radius: 50,
              latitude: userAddressCoordinate.latitude,
              longitude: userAddressCoordinate.longitude,
              notifyOnEntry: true,
              notifyOnExit: true,
              extras: {
                "route_id": 1234
              }
          )).then((bool success) {
            print('[addGeofence] SUCCESS: {${userAddressCoordinate.latitude} ${userAddressCoordinate.longitude}} ');
          }).catchError((dynamic error) {
            print('[addGeofence] FAILURE: $error');
          });
        }
      });

      // 4.  Configure the plugin
      await bg.BackgroundGeolocation.ready(bg.Config(
        url: kUrlFirebaseTracking,
        headers: {"content-type": "application/json"},
        httpRootProperty: 'data',
        locationTemplate: locationTemplate,
        params: {"userId": userId},
        autoSync: true,
        autoSyncThreshold: 5,
        batchSync: true,
        maxBatchSize: 50,
        maxDaysToPersist: 7,
        reset: true,
        debug: true,
        logLevel: bg.Config.LOG_LEVEL_VERBOSE,
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: 15.0,
        stopOnTerminate: false,
        startOnBoot: true,
        enableHeadless: true,
      )).then((bg.State state) async {
        print("[ready] ${state.toMap()}");

        await bg.BackgroundGeolocation.start();

        bg.BackgroundGeolocation.changePace(true);
      }).catchError((error) {
        print('[ready] ERROR: $error');
      });
    }
  }

  static Future<void> stopBackgroundLocation() async {
    await bg.BackgroundGeolocation.stop();
  }

  static Future<Map<String, dynamic>> _firebaseUser() async {
    bool monitored = false;
    GeoPoint geoPoint;

    /// Get the currently signed-in [FirebaseUser]
    FirebaseUser user = await FirebaseAuth.instance.currentUser();
    if (user != null) {
      final userDocument =
      Firestore.instance.collection(kUsers).document(user.uid);

      await userDocument.get().then((snapshot) {
        if (snapshot.exists) {
          List<String> listHealthStatus = ['ODP', 'PDP', 'OTG', 'CONFIRMED'];
          String userHealthStatus = snapshot.data['health_status'];

          monitored = listHealthStatus.contains(userHealthStatus);
          geoPoint = snapshot.data['location'];
        }
      });
    }

    Map<String, dynamic> result = {
      'isMonitoredUser': monitored,
      'location': geoPoint
    };

    return result;
  }

  static void _onLocation(bg.Location location) {
    print('[location] - $location');
  }

  static void _onGeofence(bg.GeofenceEvent event) {
    print('[geofence] ${event.identifier}, ${event.action}');

    try {
      NotificationHelper().showNotification(
          '${event.action} ${event.identifier}',
          'Anda ${(event.action == 'ENTER')
              ? 'memasuki'
              : 'keluar dari' } zona merah COVID-19',
          payload: '[geofence] ${event.identifier}, ${event.action}',
          onSelectNotification: (String payload) async {
            if (payload != null) {
              print('notification payload: ' + payload);
            }
          });
    } catch (e) {
      print('[geofence] Notification ${e.toString()}');
    }
  }

  static void _onLocationError(bg.LocationError error) {
    print('[location] ERROR - $error');
  }

  static void _onMotionChange(bg.Location location) {
    print('[motionchange] - $location');
  }

  static void _onActivityChange(bg.ActivityChangeEvent event) {
    print('[activitychange] - $event');
  }

  static void _onProviderChange(bg.ProviderChangeEvent event) {
    print('$event');
  }

  static void _onConnectivityChange(bg.ConnectivityChangeEvent event) {
    print('$event');
  }

  static void _onHttp(bg.HttpEvent event) {
    print('[http] success? ${event.success}, status? ${event.status}');
  }

  static Future<void> _onStatusRequested(BuildContext context,
      Map<Permission, PermissionStatus> statuses, {GeoPoint userAddressCoordinate}) async {
    if (statuses[Permission.locationAlways].isGranted &&
        statuses[Permission.activityRecognition].isGranted) {
      await _configureBackgroundLocation(userAddressCoordinate: userAddressCoordinate);
      await actionSendLocation();
      AnalyticsHelper.setLogEvent(Analytics.permissionGrantedLocation);
    } else {
      AnalyticsHelper.setLogEvent(Analytics.permissionDeniedLocation);
    }
  }
}
