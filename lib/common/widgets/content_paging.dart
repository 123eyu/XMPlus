import 'package:flutter/material.dart';

import '../../services/app_log.dart';
import 'adaptive_text.dart';

class ContentPaging extends StatelessWidget {
  const ContentPaging({
    required this.page,
    required this.total,
    required this.pageSize,
    required this.busy,
    required this.onPage,
    super.key,
  });
  final int page, total, pageSize;
  final bool busy;
  final Future<void> Function(int) onPage;

  Future<void> _jumpToPage(BuildContext context) async {
    AppLog.instance.trace(
      'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage',
    );

    final last = (total / pageSize).ceil().clamp(1, 10000);
    final form = GlobalKey<FormState>();
    var selected = page;
    final target = await showDialog<int>(
      context: context,
      builder: (context) {
        AppLog.instance.trace(
          'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage.closure#1',
        );

        void submit() {
          AppLog.instance.trace(
            'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage.closure#1.submit',
          );

          if (!form.currentState!.validate()) return;
          form.currentState!.save();
          Navigator.of(context).pop(selected);
        }

        return AlertDialog(
          title: const Text('跳转页码'),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: '$page',
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '页码',
                helperText: '请输入 1–$last 页',
              ),
              validator: (value) {
                AppLog.instance.trace(
                  'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage.closure#1.closure#1',
                );

                if (value == null || !RegExp(r'^[0-9]+$').hasMatch(value))
                  return '请输入数字页码';
                final number = int.tryParse(value);
                if (number == null || number < 1 || number > last)
                  return '页码须在 1–$last 之间';
                return null;
              },
              onSaved: (value) {
                AppLog.instance.trace(
                  'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage.closure#1.closure#2',
                );
                selected = int.parse(value!);
              },
              onFieldSubmitted: (_) {
                AppLog.instance.trace(
                  'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage.closure#1.closure#3',
                );
                submit();
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                AppLog.instance.trace(
                  'lib/common/widgets/content_paging.dart::ContentPaging._jumpToPage.closure#1.closure#4',
                );
                Navigator.of(context).pop();
              },
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('跳转')),
          ],
        );
      },
    );
    if (target != null && context.mounted && !busy) await onPage(target);
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/common/widgets/content_paging.dart::ContentPaging.build',
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一页',
            onPressed: busy || page <= 1
                ? null
                : () {
                    AppLog.instance.trace(
                      'lib/common/widgets/content_paging.dart::ContentPaging.build.closure#1',
                    );
                    onPage(page - 1);
                  },
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: TextButton(
              onPressed: busy
                  ? null
                  : () {
                      AppLog.instance.trace(
                        'lib/common/widgets/content_paging.dart::ContentPaging.build.closure#2',
                      );
                      _jumpToPage(context);
                    },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdaptiveText(
                    '第 $page / ${(total / pageSize).ceil().clamp(1, 10000)} 页',
                  ),
                  AdaptiveText(
                    '共 $total 项',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '下一页',
            onPressed: busy || page * pageSize >= total
                ? null
                : () {
                    AppLog.instance.trace(
                      'lib/common/widgets/content_paging.dart::ContentPaging.build.closure#3',
                    );
                    onPage(page + 1);
                  },
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
