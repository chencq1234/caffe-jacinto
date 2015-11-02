#include <vector>

#include "caffe/layer.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/vision_layers.hpp"

namespace caffe {

template <typename Dtype, typename Mtype>
__global__ void LRNFillScale(const int nthreads, const Dtype* const in,
    const int num, const int channels, const int height,
    const int width, const int size, const Mtype alpha_over_size,
    const Mtype k, Dtype* scale) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // find out the local offset
    const int w = index % width;
    const int h = (index / width) % height;
    const int n = index / width / height;
    const int offset = (n * channels * height + h) * width + w;
    const int step = height * width;
    const Dtype* const in_off = in + offset;
    Dtype* const scale_off = scale + offset;
    int head = 0;
    const int pre_pad = (size - 1) / 2;
    const int post_pad = size - pre_pad - 1;
    Mtype accum_scale(0.);
    // fill the scale at [n, :, h, w]
    // accumulate values
    while (head < post_pad && head < channels) {
      accum_scale += Get<Mtype>(in_off[head * step] * in_off[head * step]);
      ++head;
    }
    // both add and subtract
    while (head < channels) {
      accum_scale += Get<Mtype>(in_off[head * step] * in_off[head * step]);
      if (head - size >= 0) {
        accum_scale -= Get<Mtype>(in_off[(head - size) * step]
                       * in_off[(head - size) * step]);
      }
      scale_off[(head - post_pad) * step] = Get<Dtype>(k + accum_scale * alpha_over_size);
      ++head;
    }
    // subtract only
    while (head < channels + post_pad) {
      if (head - size >= 0) {
        accum_scale -= Get<Mtype>(in_off[(head - size) * step]
                       * in_off[(head - size) * step]);
      }
      scale_off[(head - post_pad) * step] = Get<Dtype>(k + accum_scale * alpha_over_size);
      ++head;
    }
  }
}


template <typename Dtype, typename Mtype>
void LRNLayer<Dtype,Mtype>::Forward_gpu(const vector<Blob<Dtype,Mtype>*>& bottom,
    const vector<Blob<Dtype,Mtype>*>& top) {
  switch (this->layer_param_.lrn_param().norm_region()) {
  case LRNParameter_NormRegion_ACROSS_CHANNELS:
    CrossChannelForward_gpu(bottom, top);
    break;
  case LRNParameter_NormRegion_WITHIN_CHANNEL:
    WithinChannelForward(bottom, top);
    break;
  default:
    LOG(FATAL) << "Unknown normalization region.";
  }
}

// TODO: check if it would be faster to just put it into the previous kernel.
template <typename Dtype, typename Mtype>
__global__ void LRNComputeOutput(const int nthreads, const Dtype* const in,
    const Dtype* scale, const Dtype negative_beta, Dtype* out) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    out[index] = Get<Dtype>( Get<Mtype>(in[index]) *
    		pow(Get<Mtype>(scale[index]), Get<Mtype>(negative_beta)) );
  }
}

template <typename Dtype, typename Mtype>
void LRNLayer<Dtype,Mtype>::CrossChannelForward_gpu(
    const vector<Blob<Dtype,Mtype>*>& bottom, const vector<Blob<Dtype,Mtype>*>& top) {
  // First, compute scale
  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* top_data = top[0]->mutable_gpu_data();
  Dtype* scale_data = scale_.mutable_gpu_data();
  // We will launch one kernel for each pixel location, and have the kernel
  // go through all the channels.
  int n_threads = num_ * height_ * width_;
  // NOLINT_NEXT_LINE(whitespace/operators)
  LRNFillScale<Dtype,Mtype><<<CAFFE_GET_BLOCKS(n_threads), CAFFE_CUDA_NUM_THREADS>>>(
      n_threads, bottom_data, num_, channels_, height_, width_, size_,
      alpha_ / size_, k_, scale_data);
  CUDA_POST_KERNEL_CHECK;
  n_threads = bottom[0]->count();
  // NOLINT_NEXT_LINE(whitespace/operators)
  LRNComputeOutput<Dtype,Mtype><<<CAFFE_GET_BLOCKS(n_threads), CAFFE_CUDA_NUM_THREADS>>>(
      n_threads, bottom_data, scale_data, Get<Dtype>(-beta_), top_data);
  CUDA_POST_KERNEL_CHECK;
}
template void LRNLayer<float,float>::CrossChannelForward_gpu(
    const vector<Blob<float,float>*>& bottom, const vector<Blob<float,float>*>& top);
template void LRNLayer<double,double>::CrossChannelForward_gpu(
    const vector<Blob<double,double>*>& bottom, const vector<Blob<double,double>*>& top);
#if NATIVE_FP16_SUPPORTED
template void LRNLayer<float16,float16>::CrossChannelForward_gpu(
    const vector<Blob<float16,float16>*>& bottom, const vector<Blob<float16,float16>*>& top);
#else
template void LRNLayer<float16,float>::CrossChannelForward_gpu(
    const vector<Blob<float16,float>*>& bottom, const vector<Blob<float16,float>*>& top);
#endif


template <typename Dtype, typename Mtype>
void LRNLayer<Dtype,Mtype>::Backward_gpu(const vector<Blob<Dtype,Mtype>*>& top,
    const vector<bool>& propagate_down, const vector<Blob<Dtype,Mtype>*>& bottom) {
  switch (this->layer_param_.lrn_param().norm_region()) {
  case LRNParameter_NormRegion_ACROSS_CHANNELS:
    CrossChannelBackward_gpu(top, propagate_down, bottom);
    break;
  case LRNParameter_NormRegion_WITHIN_CHANNEL:
    WithinChannelBackward(top, propagate_down, bottom);
    break;
  default:
    LOG(FATAL) << "Unknown normalization region.";
  }
}

template <typename Dtype, typename Mtype>
__global__ void LRNComputeDiff(const int nthreads,
    const Dtype* const bottom_data, const Dtype* const top_data,
    const Dtype* const scale, const Dtype* const top_diff,
    const int num, const int channels, const int height,
    const int width, const int size, const Mtype negative_beta,
    const Mtype cache_ratio,
    Dtype* bottom_diff) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // find out the local offset
    const int w = index % width;
    const int h = (index / width) % height;
    const int n = index / width / height;
    const int offset = (n * channels * height + h) * width + w;
    const int step = height * width;
    const Dtype* const bottom_off = bottom_data + offset;
    const Dtype* const top_off = top_data + offset;
    const Dtype* const scale_off = scale + offset;
    const Dtype* const top_diff_off = top_diff + offset;
    Dtype* const bottom_diff_off = bottom_diff + offset;
    int head = 0;
    const int pre_pad = size - (size + 1) / 2;
    const int post_pad = size - pre_pad - 1;
    Mtype accum_ratio(0.);
    // accumulate values
    while (head < post_pad && head < channels) {
      accum_ratio += Get<Mtype>(top_diff_off[head * step] * top_off[head * step] /
          scale_off[head * step]);
      ++head;
    }
    // both add and subtract
    while (head < channels) {
      accum_ratio += Get<Mtype>(top_diff_off[head * step] * top_off[head * step] /
          scale_off[head * step]);
      if (head - size >= 0) {
        accum_ratio -= Get<Mtype>(top_diff_off[(head - size) * step] *
            top_off[(head - size) * step] / scale_off[(head - size) * step]);
      }
      bottom_diff_off[(head - post_pad) * step] =
          top_diff_off[(head - post_pad) * step]
            * pow(Get<Mtype>(scale_off[(head - post_pad) * step]), negative_beta)
          - cache_ratio * Get<Mtype>(bottom_off[(head - post_pad) * step] * accum_ratio);
      ++head;
    }
    // subtract only
    while (head < channels + post_pad) {
      if (head - size >= 0) {
        accum_ratio -= Get<Mtype>(top_diff_off[(head - size) * step] *
            top_off[(head - size) * step] / scale_off[(head - size) * step]);
      }
      bottom_diff_off[(head - post_pad) * step] =
          top_diff_off[(head - post_pad) * step]
            * pow(Get<Mtype>(scale_off[(head - post_pad) * step]), negative_beta)
          - cache_ratio * Get<Mtype>(bottom_off[(head - post_pad) * step]) * accum_ratio;
      ++head;
    }
  }
}

template <typename Dtype, typename Mtype>
void LRNLayer<Dtype,Mtype>::CrossChannelBackward_gpu(
    const vector<Blob<Dtype,Mtype>*>& top, const vector<bool>& propagate_down,
    const vector<Blob<Dtype,Mtype>*>& bottom) {
  int n_threads = num_ * height_ * width_;
  // NOLINT_NEXT_LINE(whitespace/operators)
  LRNComputeDiff<Dtype,Mtype><<<CAFFE_GET_BLOCKS(n_threads), CAFFE_CUDA_NUM_THREADS>>>(
      n_threads, bottom[0]->gpu_data(), top[0]->gpu_data(),
      scale_.gpu_data(), top[0]->gpu_diff(), num_, channels_, height_, width_,
      size_, -beta_, Mtype(2. * alpha_ * beta_ / size_),
      bottom[0]->mutable_gpu_diff());
}

template void LRNLayer<float,float>::CrossChannelBackward_gpu(
    const vector<Blob<float,float>*>& top, const vector<bool>& propagate_down,
    const vector<Blob<float,float>*>& bottom);
template void LRNLayer<double,double>::CrossChannelBackward_gpu(
    const vector<Blob<double,double>*>& top, const vector<bool>& propagate_down,
    const vector<Blob<double,double>*>& bottom);
#if NATIVE_FP16_SUPPORTED
template void LRNLayer<float16,float16>::CrossChannelBackward_gpu(
    const vector<Blob<float16,float16>*>& top, const vector<bool>& propagate_down,
    const vector<Blob<float16,float16>*>& bottom);
#else
template void LRNLayer<float16,float>::CrossChannelBackward_gpu(
    const vector<Blob<float16,float>*>& top, const vector<bool>& propagate_down,
    const vector<Blob<float16,float>*>& bottom);
#endif


INSTANTIATE_LAYER_GPU_FUNCS(LRNLayer);

}  // namespace caffe
