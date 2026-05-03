// Contenido para parchis_server/lib/models/cell.dart

import 'package:parchis_server/models/board_action.dart';

enum CellType { normal, action }

class Cell {

  Cell({
    required this.number,
    this.type = CellType.normal,
    this.action,
  });
  final int number;
  final CellType type;
  final BoardAction? action;

  bool get hasAction => action != null;
}
