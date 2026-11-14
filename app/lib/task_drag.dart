import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'domain/models.dart';

class TaskDragHandle extends StatelessWidget {
  final TaskItem task;
  final Widget child;
  const TaskDragHandle({super.key, required this.task, required this.child});
  @override
  Widget build(BuildContext context) =>
      _ItemDragHandle<TaskItem>(value: task, label: task.name, child: child);
}

class TaskGroupDragHandle extends StatelessWidget {
  final TaskGroup group;
  final Widget child;
  final bool enabled;
  const TaskGroupDragHandle(
      {super.key,
      required this.group,
      required this.child,
      this.enabled = true});
  @override
  Widget build(BuildContext context) => _ItemDragHandle<TaskGroup>(
      value: group, label: group.name, enabled: enabled, child: child);
}

class GroupHeaderDropTarget extends StatelessWidget {
  final String groupId;
  final void Function(String sourceId) onAccept;
  final Widget child;
  const GroupHeaderDropTarget(
      {super.key,
      required this.groupId,
      required this.onAccept,
      required this.child});
  @override
  Widget build(BuildContext context) => DragTarget<TaskGroup>(
      onWillAcceptWithDetails: (details) => details.data.id != groupId,
      onAcceptWithDetails: (details) => onAccept(details.data.id),
      builder: (context, candidates, rejected) => DecoratedBox(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: candidates.isEmpty
                  ? null
                  : Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: .14)),
          child: child));
}

class _ItemDragHandle<T extends Object> extends StatefulWidget {
  final T value;
  final String label;
  final bool enabled;
  final Widget child;
  const _ItemDragHandle(
      {required this.value,
      required this.label,
      required this.child,
      this.enabled = true});

  @override
  State<_ItemDragHandle<T>> createState() => _ItemDragHandleState<T>();
}

class _ItemDragHandleState<T extends Object> extends State<_ItemDragHandle<T>>
    with AutomaticKeepAliveClientMixin {
  EdgeDraggingAutoScroller? autoScroller;
  bool dragging = false;

  @override
  bool get wantKeepAlive => dragging;

  @override
  void dispose() {
    autoScroller?.stopAutoScroll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Draggable<T>(
      data: widget.value,
      maxSimultaneousDrags: widget.enabled ? 1 : 0,
      allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () {
        dragging = true;
        updateKeepAlive();
        final scrollable = Scrollable.maybeOf(context);
        if (scrollable != null) {
          autoScroller =
              EdgeDraggingAutoScroller(scrollable, velocityScalar: 40);
        }
      },
      onDragUpdate: (details) => autoScroller?.startAutoScrollIfNecessary(
          Rect.fromCenter(
              center: details.globalPosition, width: 32, height: 64)),
      onDragEnd: (_) {
        autoScroller?.stopAutoScroll();
        if (mounted) {
          dragging = false;
          updateKeepAlive();
        }
      },
      feedback: Transform.translate(
          offset: const Offset(12, 12),
          child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                  width: 260,
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(widget.label,
                          maxLines: 2, overflow: TextOverflow.ellipsis))))),
      childWhenDragging: Opacity(opacity: .35, child: widget.child),
      child: widget.child,
    );
  }
}

class TaskDropTarget extends StatefulWidget {
  final String? taskId;
  final void Function(TaskItem task, bool after) onAccept;
  final Widget child;
  const TaskDropTarget(
      {super.key, this.taskId, required this.onAccept, required this.child});

  @override
  State<TaskDropTarget> createState() => _TaskDropTargetState();
}

class _TaskDropTargetState extends State<TaskDropTarget> {
  bool after = false;

  bool isAfter(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    return box.globalToLocal(global).dy >= box.size.height / 2;
  }

  @override
  Widget build(BuildContext context) => DragTarget<TaskItem>(
        onWillAcceptWithDetails: (details) =>
            details.data.status != 'done' && details.data.id != widget.taskId,
        onMove: (details) {
          final next = isAfter(details.offset);
          if (next != after) setState(() => after = next);
        },
        onAcceptWithDetails: (details) {
          final box = context.findRenderObject()! as RenderBox;
          if ((Offset.zero & box.size)
              .contains(box.globalToLocal(details.offset))) {
            widget.onAccept(details.data, isAfter(details.offset));
          }
        },
        builder: (context, candidates, rejected) {
          final hovering = candidates.isNotEmpty;
          final color = Theme.of(context).colorScheme.primary;
          final border = BorderSide(
              color: hovering ? color : Colors.transparent, width: 2);
          return DecoratedBox(
              decoration: BoxDecoration(
                  color: hovering ? color.withValues(alpha: .10) : null,
                  borderRadius:
                      widget.taskId == null ? BorderRadius.circular(8) : null,
                  border: widget.taskId == null
                      ? Border.fromBorderSide(border)
                      : Border(
                          top: after ? BorderSide.none : border,
                          bottom: after ? border : BorderSide.none)),
              child: widget.child);
        },
      );
}
