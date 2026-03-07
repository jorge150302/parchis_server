// Contenido para parchis_server/lib/logic/board_presets.dart

import '../models/board_action.dart';

final classicActionPositions = [
  13, 15, 19, 24, 29, 37, 43, 49, 56, 66, 72, 76, 79, 83, 93, 97
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
  BoardAction.moveTo(18),       // 56
  BoardAction.skipTurn(),       // 66
  BoardAction.rollAgain(),      // 72
  BoardAction.moveTo(18),       // 76
  BoardAction.goToStart(),      // 79
  BoardAction.moveTo(23),       // 83
  BoardAction.goToStart(),      // 93
  BoardAction.moveTo(70),       // 97
];
