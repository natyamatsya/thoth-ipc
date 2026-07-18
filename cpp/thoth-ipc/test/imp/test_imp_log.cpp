
#include <iostream>
#include <string>

#include "../archive/test.h"

#include "thoth-ipc/imp/log.h"

TEST(log, logger) {
  {
    THOTH_IPC_LOG();
    log.info("hello");
  }
  {
    THOTH_IPC_LOG();
    log.info("hello 2");
  }
  {
    THOTH_IPC_LOG();
    log.info("hello ", 3);
  }
  SUCCEED();
}

TEST(log, custom) {
  struct log {
    std::string i;
    std::string e;
  } ll_data;
  auto ll = [&ll_data](auto &&ctx) {
    auto s = ipc::fmt(ctx.params);
    if (ctx.level == ipc::log::level::error) ll_data.e += s + " ";
    else
    if (ctx.level == ipc::log::level::info ) ll_data.i += s + " ";
  };

  THOTH_IPC_LOG(ll);

  log.info ("hello", " world");
  log.error("failed", ":");
  log.info ("log", '-', "pt");
  log.error("whatever");

  EXPECT_EQ(ll_data.i, "hello world log-pt ");
  EXPECT_EQ(ll_data.e, "failed: whatever ");
}
