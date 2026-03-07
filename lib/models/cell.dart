// Contenido para parchis_server/lib/models/cell.dart

import 'board_action.dart';

enum CellType { normal, action }

class Cell {
  final int number;
  final CellType type;
  final BoardAction? action;

  Cell({
    required this.number,
    this.type = CellType.normal,
    this.action,
  });

  bool get hasAction => action != null;
}
