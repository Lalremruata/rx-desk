import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'new_bill_request.g.dart';

/// Bumped by the header's "New bill" button (and F2). The Billing screen
/// listens and focuses its search box.
@Riverpod(keepAlive: true)
class NewBillRequest extends _$NewBillRequest {
  @override
  int build() => 0;

  void request() => state++;
}
