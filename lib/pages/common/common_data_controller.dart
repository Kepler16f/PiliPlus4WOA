import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';

abstract class CommonDataController<R, T> extends CommonController<R, T> {
  @override
  Rx<LoadingState<T>> loadingState = LoadingState<T>.loading().obs;

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading) return;
    isLoading = true;
    // ARM64 修改版（2026-09-28）：与 CommonListController.queryData 同一处修复
    // （那边有完整说明）—— 取数过程必须保证 isLoading 一定复位、loadingState 一定
    // 离开 Loading，否则页面会永远停在加载动画上，且之后所有刷新都变成空操作。
    try {
      final LoadingState<R> res = await customGetData();
      if (res is Success<R>) {
        if (!customHandleResponse(isRefresh, res)) {
          loadingState.value = res as LoadingState<T>;
        }
      } else if (isRefresh) {
        final kept = handleError(res is Error ? res.errMsg : null);
        // 还停在 Loading = 没有任何可保留的数据，必须把错误交出去。
        if (!kept || loadingState.value is Loading) {
          loadingState.value = res as Error;
        }
      }
    } catch (e, s) {
      if (isRefresh && loadingState.value is Loading) {
        loadingState.value = Error(e.toString());
      }
      Utils.reportError('queryData failed: \$e', s);
    } finally {
      isLoading = false;
    }
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<T>.loading();
    return super.onReload();
  }
}
