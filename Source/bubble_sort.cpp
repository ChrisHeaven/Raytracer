#include <vector>
#include <iostream>

void bubble_sort(std::vector<int>& data)
{
    const std::size_t n = data.size();
    if (n < 2) return;

    for (std::size_t i = 0; i + 1 < n; ++i)
    {
        bool swapped = false;
        for (std::size_t j = 0; j + 1 < n - i; ++j)
        {
            if (data[j] > data[j + 1])
            {
                std::swap(data[j], data[j + 1]);
                swapped = true;
            }
        }
        if (!swapped) break;
    }
}

int main()
{
    std::vector<int> arr{5, 1, 4, 2, 8};
    bubble_sort(arr);

    for (std::size_t i = 0; i < arr.size(); ++i)
    {
        std::cout << arr[i] << (i + 1 == arr.size() ? '\n' : ' ');
    }

    return 0;
}

