// Simple bubble sort implementation for demonstration.
// This file is currently standalone and not used by the raytracer.

#include <vector>
#include <iostream>

// 冒泡排序：对整数数组从小到大排序
void bubble_sort(std::vector<int>& data)
{
    const std::size_t n = data.size();
    if (n <= 1)
        return;

    bool swapped = true;
    for (std::size_t i = 0; i < n - 1 && swapped; ++i)
    {
        swapped = false;
        for (std::size_t j = 0; j < n - 1 - i; ++j)
        {
            if (data[j] > data[j + 1])
            {
                std::swap(data[j], data[j + 1]);
                swapped = true;
            }
        }
    }
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

