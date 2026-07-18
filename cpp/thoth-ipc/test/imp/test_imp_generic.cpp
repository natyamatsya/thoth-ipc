
#include "../archive/test.h"

#include "thoth-ipc/imp/generic.h"
#include "thoth-ipc/imp/detect_plat.h"

TEST(generic, countof) {
  struct {
    constexpr int Size() const noexcept { return 3; }
  } sv;
  EXPECT_FALSE(thoth::detail_countof::trait_has_size<decltype(sv)>::value);
  EXPECT_TRUE (thoth::detail_countof::trait_has_Size<decltype(sv)>::value);

  std::vector<int> vec {1, 2, 3, 4, 5};
  int arr[] {7, 6, 5, 4, 3, 2, 1};
  auto il = {9, 7, 6, 4, 3, 1, 5};
  EXPECT_EQ(thoth::countof(sv) , sv.Size());
  EXPECT_EQ(thoth::countof(vec), vec.size());
  EXPECT_EQ(thoth::countof(arr), sizeof(arr) / sizeof(arr[0]));
  EXPECT_EQ(thoth::countof(il) , il.size());
}

TEST(generic, dataof) {
  struct {
    int *Data() const noexcept { return (int *)this; }
  } sv;
  EXPECT_FALSE(thoth::detail_dataof::trait_has_data<decltype(sv)>::value);
  EXPECT_TRUE (thoth::detail_dataof::trait_has_Data<decltype(sv)>::value);

  std::vector<int> vec {1, 2, 3, 4, 5};
  int arr[] {7, 6, 5, 4, 3, 2, 1};
  auto il = {9, 7, 6, 4, 3, 1, 5};
  EXPECT_EQ(thoth::dataof(sv) , sv.Data());
  EXPECT_EQ(thoth::dataof(vec), vec.data());
  EXPECT_EQ(thoth::dataof(arr), arr);
  EXPECT_EQ(thoth::dataof(il) , il.begin());
}

TEST(generic, horrible_cast) {
  struct A {
    int a_;
  } a {123};

  struct B {
    char a_[sizeof(int)];
  } b = thoth::horrible_cast<B>(a);

  EXPECT_EQ(b.a_[1], 0);
  EXPECT_EQ(b.a_[2], 0);
#if THOTH_IPC_ENDIAN_LIT
  EXPECT_EQ(b.a_[0], 123);
  EXPECT_EQ(b.a_[3], 0);
#else
  EXPECT_EQ(b.a_[3], 123);
  EXPECT_EQ(b.a_[0], 0);
#endif

#if THOTH_IPC_ENDIAN_LIT
  EXPECT_EQ(thoth::horrible_cast<std::uint32_t>(0xff00'0000'0001ll), 1);
#else
  EXPECT_EQ(thoth::horrible_cast<std::uint32_t>(0xff00'0000'0001ll), 0xff00);
#endif
}

#if defined(THOTH_IPC_CPP_17)
TEST(generic, in_place) {
  EXPECT_TRUE((std::is_same<std::in_place_t, thoth::in_place_t>::value));
  [](thoth::in_place_t) {}(std::in_place);
  [](std::in_place_t) {}(thoth::in_place);
}
#endif/*THOTH_IPC_CPP_17*/

TEST(generic, copy_cvref) {
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int   , long>, long   >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int & , long>, long & >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int &&, long>, long &&>()));

  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int const   , long>, long const   >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int const & , long>, long const & >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int const &&, long>, long const &&>()));

  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int volatile   , long>, long volatile   >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int volatile & , long>, long volatile & >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int volatile &&, long>, long volatile &&>()));

  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int const volatile   , long>, long const volatile   >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int const volatile & , long>, long const volatile & >()));
  EXPECT_TRUE((std::is_same<thoth::copy_cvref_t<int const volatile &&, long>, long const volatile &&>()));
}
