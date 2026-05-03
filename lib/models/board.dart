// Contenido para parchis_server/lib/models/board.dart

import 'package:parchis_server/models/cell.dart';

class Board {

  Board(this.cells);
  final List<Cell> cells;

  int get finalPosition => cells.length;

  bool isValidPosition(int position) {
    return position >= 1 && position <= finalPosition;
  }

  Cell getCell(int position) {
    // En el servidor, asumimos que la posición es siempre válida.
    return cells[position - 1];
  }
}
