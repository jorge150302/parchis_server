// Contenido para parchis_server/lib/logic/board_generator.dart

import '../models/board.dart';
import '../models/cell.dart';
import '../models/board_action.dart';

Board generateBoard(List<int> actionPositions, List<BoardAction> actions, {int totalCells = 10}) {
  List<Cell> cells = [];
  int actionIndex = 0;

  for (int i = 1; i <= totalCells; i++) {
    // Solo añadimos acciones si la posición es válida dentro del nuevo tamaño
    if (actionIndex < actionPositions.length && i == actionPositions[actionIndex]) {
      cells.add(Cell(
        number: i,
        type: CellType.action,
        action: actions[actionIndex],
      ));
      actionIndex++;
    } else {
      cells.add(Cell(number: i));
    }
  }

  return Board(cells);
}
