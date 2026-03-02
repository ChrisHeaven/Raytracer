// Simple quick sort implementation for demonstration.
// This file is currently standalone and not used by the raytracer.

#include <vector>
#include <iostream>

// 快速排序：对整数数组从小到大排序
namespace
{
    void quick_sort_impl(std::vector<int>& data, int left, int right)
    {
        if (left >= right)
            return;

        int i = left;
        int j = right;
        int pivot = data[left + (right - left) / 2];

        while (i <= j)
        {
            while (data[i] < pivot) ++i;
            while (data[j] > pivot) --j;

            if (i <= j)
            {
                std::swap(data[i], data[j]);
                ++i;
                --j;
            }
        }

        if (left < j)
            quick_sort_impl(data, left, j);
        if (i < right)
            quick_sort_impl(data, i, right);
    }
}

void bubble_sort(std::vector<int>& data)
{
    if (data.size() <= 1)
        return;

    quick_sort_impl(data, 0, static_cast<int>(data.size()) - 1);
}

// 一个简单的测试 main，可按需要删除或修改
int main()
{
    std::vector<int> arr = {5, 1, 4, 2, 8};

    bubble_sort(arr);

    for (std::size_t i = 0; i < arr.size(); ++i)
    {
        std::cout << arr[i] << (i + 1 == arr.size() ? '\n' : ' ');
    }

    return 0;
}

