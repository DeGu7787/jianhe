import 'dart:io';

import 'package:jianhe_cli/jianhe_cli.dart';

Future<void> main(List<String> arguments) async {
  final result = await JianheCliRunner().run(arguments);
  await stdout.flush();
  await stderr.flush();
  exitCode = result;
}
