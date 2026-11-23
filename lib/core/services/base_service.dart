import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract class BaseService {
  final Ref? serviceRef;

  BaseService({this.serviceRef});
}
