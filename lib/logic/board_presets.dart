// Contenido para parchis_server/lib/logic/board_presets.dart

import 'package:parchis_server/models/board_action.dart';

final classicActionPositions = [
  13, 15, 19, 24, 29, 37, 43, 49, 58, 66, 72, 78, 81, 83, 93, 97,
];

final classicActions = [
  BoardAction.goToStart(),      // 13
  BoardAction.rollAgain(),      // 15
  BoardAction.skipTurn(),       // 19
  BoardAction.moveTo(63),       // 24
  BoardAction.rollAgain(),      // 29
  BoardAction.skipTurn(),       // 37
  BoardAction.moveTo(25),       // 43
  BoardAction.moveTo(70),       // 49
  BoardAction.moveTo(25),       // 58
  BoardAction.skipTurn(),       // 66
  BoardAction.rollAgain(),      // 72
  BoardAction.moveTo(45),       // 78
  BoardAction.moveTo(50),       // 81
  BoardAction.moveTo(55),       // 83
  BoardAction.moveTo(65),       // 93
  BoardAction.moveTo(90),       // 97
];
