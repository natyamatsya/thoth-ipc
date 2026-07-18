#include <iostream>

#include "../archive/test.h"

#include "thoth-ipc/imp/error.h"
#include "thoth-ipc/imp/fmt.h"

TEST(error, error_code) {
  std::error_code ecode;
  EXPECT_FALSE(ecode);
  std::cout << ipc::fmt(ecode, '\n');
}
