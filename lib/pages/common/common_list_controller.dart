import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';

abstract class CommonListController<R, T> extends CommonController<R, T> {
  int page = 1;
  bool isEnd = false;
  bool? hasFooter;

  @override
  Rx<LoadingState<List<T>?>> loadingState =
      LoadingState<List<T>?>.loading().obs;

  void handleListResponse(List<T> dataList) {}

  List<T>? getDataList(R response) {
    return response as List<T>?;
  }

  void checkIsEnd(int length) {}

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading || (!isRefresh && isEnd)) return;
    isLoading = true;
    // ARM64 修改版（2026-09-28）：取数过程必须保证 isLoading 一定复位、且
    // loadingState 一定离开 Loading —— 否则页面永远停在加载动画上。用户报的
    // 「第一次打开评论区/首页，刷新动画卡住，退出重进才好」正是这两条：
    //
    //   1. customGetData() 抛异常（评论走 gRPC、首页走 HTTP，网络/风控异常都
    //      常见）时原来没有 try/finally：isLoading 永久停在 true，之后每次
    //      queryData（含下拉刷新、加载更多）都在上面的守卫处直接 return，页面
    //      再也刷不动，只有重建控制器（退出重进）才恢复 —— 与取流 isQuerying
    //      卡死是同一类缺陷。
    //   2. 请求失败但 handleError() 说「保留上次数据」时（RcmdController 在
    //      enableSaveLastData 打开时恒返回 true，而该开关默认就是开），原来不写
    //      loadingState；若此时还停在 Loading（压根没有可保留的数据），页面就永远
    //      停在骨架屏上。没有可保留的数据时必须给出 Error，页面才有重试入口。
    try {
      final LoadingState<R> res = await customGetData();
      if (res case Success(:final response)) {
        if (!customHandleResponse(isRefresh, res)) {
          final dataList = getDataList(response);
          if (dataList == null || dataList.isEmpty) {
            isEnd = true;
            if (isRefresh) {
              loadingState.value = Success(dataList);
            } else if (hasFooter == true) {
              loadingState.refresh();
            }
            return;
          }
          handleListResponse(dataList);
          if (isRefresh) {
            checkIsEnd(dataList.length);
            loadingState.value = Success(dataList);
          } else if (loadingState.value case Success(:final response)) {
            response!.addAll(dataList);
            checkIsEnd(response.length);
            loadingState.refresh();
          }
        }
        page++;
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
      Utils.reportError('queryData failed: $e', s);
    } finally {
      isLoading = false;
    }
  }

  @override
  Future<void> onRefresh() {
    page = 1;
    isEnd = false;
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<List<T>?>.loading();
    return super.onReload();
  }
}
