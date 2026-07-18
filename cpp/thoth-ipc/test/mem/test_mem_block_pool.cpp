
#include "../archive/test.h"

#include <utility>

#include "thoth-ipc/mem/block_pool.h"

TEST(block_pool, ctor) {
  ASSERT_TRUE ((std::is_default_constructible<thoth::mem::block_pool<1, 1>>::value));
  ASSERT_FALSE((std::is_copy_constructible<thoth::mem::block_pool<1, 1>>::value));
  ASSERT_TRUE ((std::is_move_constructible<thoth::mem::block_pool<1, 1>>::value));
  ASSERT_FALSE((std::is_copy_assignable<thoth::mem::block_pool<1, 1>>::value));
  ASSERT_FALSE((std::is_move_assignable<thoth::mem::block_pool<1, 1>>::value));
}

TEST(block_pool, allocate) {
  std::vector<void *> v;
  thoth::mem::block_pool<1, 1> pool;
  for (int i = 0; i < 100; ++i) {
    v.push_back(pool.allocate());
  }
  for (void *p: v) {
    ASSERT_FALSE(nullptr == p);
    pool.deallocate(p);
  }
  for (int i = 0; i < 100; ++i) {
    ASSERT_EQ(v[v.size() - i - 1], pool.allocate());
  }
  for (void *p: v) {
    pool.deallocate(p);
  }
}
