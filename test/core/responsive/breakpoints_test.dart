import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/responsive/breakpoints.dart';

void main() {
  group('Breakpoints', () {
    test('phone detection for small widths', () {
      expect(Breakpoints.isPhone(360), true);
      expect(Breakpoints.isPhone(400), true);
      expect(Breakpoints.isPhone(480), true);
      expect(Breakpoints.isPhone(599), true);
    });

    test('tablet detection for medium widths', () {
      expect(Breakpoints.isTablet(600), true);
      expect(Breakpoints.isTablet(768), true);
      expect(Breakpoints.isTablet(1023), true);
    });

    test('desktop detection for large widths', () {
      expect(Breakpoints.isDesktop(1024), true);
      expect(Breakpoints.isDesktop(1440), true);
      expect(Breakpoints.isDesktop(1920), true);
    });

    test('device type returns correct enum', () {
      expect(Breakpoints.deviceType(360), DeviceType.phone);
      expect(Breakpoints.deviceType(480), DeviceType.phoneLarge);
      expect(Breakpoints.deviceType(600), DeviceType.tablet);
      expect(Breakpoints.deviceType(1024), DeviceType.desktop);
    });

    test('grid columns returns correct count', () {
      expect(Breakpoints.gridColumns(360), 1);
      expect(Breakpoints.gridColumns(768), 2);
      expect(Breakpoints.gridColumns(1024), 4);
    });
  });
}
