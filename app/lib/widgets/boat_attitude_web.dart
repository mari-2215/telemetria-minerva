import 'package:web/web.dart' as web;

void updateWebModelOrientation(String elementId, String orientation) {
  web.document
      .querySelector('#$elementId')
      ?.setAttribute('orientation', orientation);
}
