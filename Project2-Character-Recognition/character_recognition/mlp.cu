#include <cuda.h>
#include <cuda_runtime.h>
#include <curand.h>
#include <cublas_v2.h>
#include "common.h"
#include "functions.h"
#include "mlp.h"
#include "device_launch_parameters.h"
#include <thrust/device_vector.h>
#include <thrust/fill.h>
#include <algorithm>
#include <array>
#include <fstream>

#define blockSize 128

int INPUT_LAYER_SIZE;
int HIDDEN_LAYER_SIZE;
int OUTPUT_LAYER_SIZE;

float *weights_IH, *weights_HO, *g_weights_IH, *g_weights_HO, *hidden, *h_sigmoid, *output, *o_softmax;
cublasHandle_t cublas_handle;

void print_matrix(const float *devA, int nr_rows_A, int nr_cols_A) {
	float *A = new float[nr_rows_A*nr_cols_A];
	cudaMemcpy(A, devA, nr_rows_A*nr_cols_A * sizeof(float), cudaMemcpyDeviceToHost);
	for (int i = 0; i < nr_rows_A; ++i) {
		for (int j = 0; j < nr_cols_A; ++j) {
			printf("%f \t", A[j * nr_rows_A + i]);
		}
		printf("\n");
	}
}

namespace StreamCompaction {
	__global__ void kernelUpSweepStepEfficient(int n, int d, float* cdata) {
		int k = (blockIdx.x * blockDim.x) + threadIdx.x;
		if (k >= n)
			return;
		int prev_step_size = 1 << d;
		int cur_step_size = 2 * prev_step_size;
		int new_offset = k * cur_step_size;
		cdata[new_offset + cur_step_size - 1] += cdata[new_offset + prev_step_size - 1];
	}
	/**
	 * Performs prefix-sum (aka scan) on idata, storing the result into odata.
	 */
	void sumArray(int n, float* sum, const float *idata) {
		// Memory Allocation and Copying
		int power_size = pow(2, ilog2ceil(n));
		float *sumArray;
		cudaMalloc((void**)&sumArray, power_size * sizeof(float));
		checkCUDAErrorFn("cudaMalloc sumArray failed!");
		cudaMemset(sumArray, 0, power_size * sizeof(float));
		cudaMemcpy(sumArray, idata, n * sizeof(float), cudaMemcpyDeviceToDevice);

		int numThreads;
		//Up Sweep
		for (int d = 0; d <= ilog2ceil(power_size) - 1; d++) {
			numThreads = pow(2, (ilog2ceil(power_size) - 1 - d));
			dim3 fullBlocks((numThreads + blockSize - 1) / blockSize);
			kernelUpSweepStepEfficient << <fullBlocks, blockSize >> > (numThreads, d, sumArray);
		}
		// Copy Back and Free Memory
		cudaMemcpy(sum, sumArray + power_size - 1, sizeof(float), cudaMemcpyDeviceToDevice);
		cudaFree(sumArray);
	}
}

namespace CharacterRecognition {
    using Common::PerformanceTimer;
    PerformanceTimer& timer()
    {
        static PerformanceTimer timer;
        return timer;
    }
        
	// Reference: https://solarianprogrammer.com/2012/05/31/matrix-multiplication-cuda-cublas-curand-thrust/
	// Matrix Multiplication
	// nr_rows_A, nr_cols_A, nr_cols_B
	void gpu_blas_mmul(const float *A, const float *B, float *C, const int nr_rows_A, const int nr_cols_A, const int nr_cols_B) {
		int lda = nr_rows_A, ldb = nr_cols_A, ldc = nr_rows_A;
		const float alf = 1;
		const float bet = 0;
		const float *alpha = &alf;
		const float *beta = &bet;
	    cublasSgemm(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_N, nr_rows_A, nr_cols_B, nr_cols_A, alpha, A, lda, B, ldb, beta, C, ldc);
	}

	/* Forward Pass
	   1. Multiply input with input and hidden layer weights
	   2. Apply Sigmoid 
	   3. Multiply hidden layer activation with hidden and output layer weights
	   4. Apply Softmax and calculate ouput
	*/
	// TODO: Can Incorporate Bias
	void forwardPass(float* dev_input) {
		// Matrix Multiply Input Layer and Weights 1
		gpu_blas_mmul(dev_input, weights_IH, hidden, 1, INPUT_LAYER_SIZE, HIDDEN_LAYER_SIZE);
		
		// Apply Sigmoid
		dim3 hiddenLayerBlocks((HIDDEN_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::sigmoidActivation<<<hiddenLayerBlocks, blockSize>>>(hidden, h_sigmoid, 1, HIDDEN_LAYER_SIZE);
		
		// Matrix Multiply Hidden layer and Weights 2
		gpu_blas_mmul(h_sigmoid, weights_HO, output, 1, HIDDEN_LAYER_SIZE, OUTPUT_LAYER_SIZE);
		//print_matrix(output, 1, OUTPUT_LAYER_SIZE);
		
		// Apply Softmax
		dim3 outputLayerBlocks((OUTPUT_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::ExponentialActivation <<<outputLayerBlocks, blockSize >>> (output, o_softmax, 1, OUTPUT_LAYER_SIZE);
		float *sum;
		cudaMalloc((void**)&sum, sizeof(float));
		StreamCompaction::sumArray(OUTPUT_LAYER_SIZE, sum, o_softmax);
		Functions::Divide << <outputLayerBlocks, blockSize >> > (o_softmax, sum, 1, OUTPUT_LAYER_SIZE);
		cudaFree(sum);
	}

	/*
		Back Propagation
		1. Calculates gradient for the weights between the hidden and output layer
		2. Calculates gradient for the weights between the input and hidden layer
		3. Updates gradients according to the learning rate
	*/
	void backwardPropagation(float* dev_input, float* dev_output, float* learning_rate) {
		// Memory Allocation
		float *temp_hidden, *temp_output;
		cudaMalloc((void**)&temp_output, OUTPUT_LAYER_SIZE * sizeof(float));
		cudaMalloc((void**)&temp_hidden, HIDDEN_LAYER_SIZE * sizeof(float));

		// Gradient of Loss w.r.t Weight2
		dim3 outputLayerBlocks((OUTPUT_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::ElementwiseSubtraction << <outputLayerBlocks, blockSize >> > (o_softmax, dev_output, temp_output, 1, OUTPUT_LAYER_SIZE);
		gpu_blas_mmul(h_sigmoid, temp_output, g_weights_HO, HIDDEN_LAYER_SIZE, 1, OUTPUT_LAYER_SIZE);

		// Gradient of Loss w.r.t Weight1
		gpu_blas_mmul(weights_HO, temp_output, temp_hidden, HIDDEN_LAYER_SIZE, OUTPUT_LAYER_SIZE, 1);
		dim3 hiddenLayerBlocks((HIDDEN_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::KernelElementwiseMultiplySigmoid << <outputLayerBlocks, blockSize >> > (temp_hidden, h_sigmoid, 1, HIDDEN_LAYER_SIZE);
		gpu_blas_mmul(dev_input, temp_hidden, g_weights_IH, INPUT_LAYER_SIZE, 1, HIDDEN_LAYER_SIZE);

		// Gradient Updates
		dim3 IHBlocks(((INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE) + blockSize - 1) / blockSize);
		Functions::Multiply << <IHBlocks, blockSize >> > (g_weights_IH, learning_rate, INPUT_LAYER_SIZE, HIDDEN_LAYER_SIZE);
		Functions::ElementwiseSubtraction << <IHBlocks, blockSize >> > (weights_IH, g_weights_IH, weights_IH, INPUT_LAYER_SIZE, HIDDEN_LAYER_SIZE);
		dim3 HOBlocks(((HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE) + blockSize - 1) / blockSize);
		Functions::Multiply << <HOBlocks, blockSize >> > (g_weights_HO, learning_rate, HIDDEN_LAYER_SIZE, OUTPUT_LAYER_SIZE);
		Functions::ElementwiseSubtraction << <HOBlocks, blockSize >> > (weights_HO, g_weights_HO, weights_HO, HIDDEN_LAYER_SIZE, OUTPUT_LAYER_SIZE);

		// Free Memory
		cudaFree(temp_hidden);
		cudaFree(temp_output);
	}

	/*
		Calculates Cross Entropy Loss and populates loss
	*/
	void calculateLoss(float* dev_output, float* loss) {
		// Memory Allocation
		float *temp_loss, *sum;
		cudaMalloc((void**)&temp_loss, OUTPUT_LAYER_SIZE * sizeof(float));
		cudaMalloc((void**)&sum, sizeof(float));

		dim3 outputLayerBlocks((OUTPUT_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::CrossEntropyLoss << <OUTPUT_LAYER_SIZE, blockSize >> > (dev_output, o_softmax, temp_loss, 1, OUTPUT_LAYER_SIZE);
		StreamCompaction::sumArray(OUTPUT_LAYER_SIZE, sum, temp_loss);
		Functions::Add << <1, 1 >> > (loss, sum, 1, 1);

		cudaFree(temp_loss);
		cudaFree(sum);
	}

	/*
		Saves model weights
	*/
	void saveModel(std::string model_file) {
		std::ofstream model_w1, model_w2;
		model_w1.open(model_file + "_w1.txt"); 
		if (!model_w1) {
			std::cerr << "Error: file could not be opened" << std::endl;
			exit(1);
		}
		float *w1 = new float[INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE];
		cudaMemcpy(w1, weights_IH, INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE * sizeof(float), cudaMemcpyDeviceToHost);
		for (int i = 0; i < INPUT_LAYER_SIZE; ++i) {
			for (int j = 0; j < HIDDEN_LAYER_SIZE; ++j) {
				model_w1 << w1[j * INPUT_LAYER_SIZE + i] << "\t";
			}
			model_w1 << "\n";
		}
		model_w1.close();

		model_w2.open(model_file + "_w2.txt");
		if (!model_w2) {
			std::cerr << "Error: file could not be opened" << std::endl;
			exit(1);
		}
		float *w2 = new float[HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE];
		cudaMemcpy(w2, weights_IH, HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE * sizeof(float), cudaMemcpyDeviceToHost);
		for (int i = 0; i < HIDDEN_LAYER_SIZE; ++i) {
			for (int j = 0; j < OUTPUT_LAYER_SIZE; ++j) {
				model_w2 << w2[j * HIDDEN_LAYER_SIZE + i] << "\t";
			}
			model_w2 << "\n";
		}
		model_w2.close();
	}

	/*
	Trains the model
	1. Creats reqiured device buffers
	2. Trains the model ( Forward Pass, Backward Pass, Loss calculation) epoch number of times
	3. Saves the model weights
	*/
	void train(float* idata, float* ilabel, int num_instances, int epochs, float learning_rate, std::string model_file) {
		float *dev_input, *dev_output, *dev_lr, *dev_instances;
		// Device Buffer for Input 
		cudaMalloc((void**)&dev_input, num_instances * INPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc dev_input failed!");
		cudaMemcpy(dev_input, idata, num_instances * INPUT_LAYER_SIZE * sizeof(float), cudaMemcpyHostToDevice);
		
		// Device Buffer for Output 
		cudaMalloc((void**)&dev_output, num_instances * OUTPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc dev_output failed!");
		cudaMemcpy(dev_output, ilabel, num_instances * OUTPUT_LAYER_SIZE * sizeof(float), cudaMemcpyHostToDevice);

		// Device Buffer for Learning Rate 
		cudaMalloc((void**)&dev_lr, sizeof(float));
		thrust::device_ptr<float> dev_ptr(dev_lr);
		thrust::fill(dev_ptr, dev_ptr + 1, learning_rate);

		// Device Buffer for Instances 
		cudaMalloc((void**)&dev_instances, sizeof(float));
		thrust::device_ptr<float> dev_instance_ptr(dev_instances);
		thrust::fill(dev_instance_ptr, dev_instance_ptr + 1, num_instances);

		// Train
		float *dev_loss;
		cudaMalloc((void**)&dev_loss, epochs * sizeof(float));
		cudaMemset(dev_loss, 0, epochs * sizeof(float));
		float *loss = new float[1];
		std::cout << "Epoch  Loss" << std::endl;
		for (int e = 0; e < epochs; e++) {
			for (int i = 0; i < num_instances; i++) {
				// Forward Pass
				forwardPass(dev_input + (i * INPUT_LAYER_SIZE));
				// Back Propagation
				backwardPropagation(dev_input + (i * INPUT_LAYER_SIZE), dev_output + (i * OUTPUT_LAYER_SIZE), dev_lr);
				// Loss Calculation
				calculateLoss(dev_output + (i * OUTPUT_LAYER_SIZE), dev_loss + e);
			}
			Functions::Divide << < 1, 1 >>>(dev_loss + e, dev_instances, 1, 1);
			std::cout << e << "  ";
			print_matrix(dev_loss + e, 1, 1);
		}
		saveModel(model_file);
	}

	/*
		Predicts ouptut for num of instances in idata variable
		and logs the target variable and the predicted variable 
		along with the confidence (prediction probability)
	*/
	void test(float* idata, float* true_labels, int num_instances) {
		float *dev_input, *output;
		int *input = new int[num_instances];
		for (int i = 0; i < num_instances; i++)
			input[i] = i;
		output = new float[OUTPUT_LAYER_SIZE];
		cudaMalloc((void**)&dev_input, num_instances * INPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc dev_input failed!");
		cudaMemcpy(dev_input, idata, num_instances * INPUT_LAYER_SIZE * sizeof(float), cudaMemcpyHostToDevice);
		std::random_shuffle(input, input + num_instances);
		for (int k = 0; k < num_instances; k++) {
			int i = input[k];
			forwardPass(dev_input + (i * INPUT_LAYER_SIZE));
			cudaMemcpy(output, o_softmax, OUTPUT_LAYER_SIZE * sizeof(float), cudaMemcpyDeviceToHost);
			float maxProbability = -1;
			int argmax = -1;
			int true_label = -1;
			for (int j = 0; j < OUTPUT_LAYER_SIZE; j++) {
				if (output[j] > maxProbability) {
					maxProbability = output[j];
					argmax = j;
				}
				if (true_labels[(i * OUTPUT_LAYER_SIZE) + j] == 1)
					true_label = j;
			}
			std::cout << "Target Variable: " << true_label << " Predicted: " << argmax << " with probability " << maxProbability << std::endl;
		}
		delete[] output;
		delete[] input;
		cudaFree(dev_input);
	}

	/*
		Initializes the model framework
		1. Allocates memory for all Weight Matrices, Gradient Matrics and Hidden Layers
		2. Initializes the weight matrices with random numbers in the range of [-1, 1]
	*/
	void init(int input_size, int hidden_size, int output_size) {
		// Initialize Layer Sizes
		INPUT_LAYER_SIZE = input_size;
		HIDDEN_LAYER_SIZE = hidden_size;
		OUTPUT_LAYER_SIZE = output_size;

		// Memory Allocation for Weight Matrices, Gradient Matrics and Hidden Layers
		cudaMalloc((void**)&weights_IH, INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc weights_IH failed!");
		cudaMalloc((void**)&weights_HO, HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc weights_HO failed!");
		cudaMalloc((void**)&g_weights_IH, INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc g_weights_IH failed!");
		cudaMalloc((void**)&g_weights_HO, HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc g_weights_HO failed!");
		cudaMalloc((void**)&hidden, HIDDEN_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc hidden failed!");
		cudaMalloc((void**)&h_sigmoid, HIDDEN_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc h_sigmoid failed!");
		cudaMalloc((void**)&output, OUTPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc output failed!");
		cudaMalloc((void**)&o_softmax, OUTPUT_LAYER_SIZE * sizeof(float));
		checkCUDAErrorFn("cudaMalloc o_softmax failed!");

		// Create a handle for CUBLAS
		cublasCreate(&cublas_handle);

		// Curand Random Number Generator and Seed
		curandGenerator_t prng;
		curandCreateGenerator(&prng, CURAND_RNG_PSEUDO_DEFAULT);
		curandSetPseudoRandomGeneratorSeed(prng, 70);

	    // Initialize weight matrices with random numbers
		curandGenerateUniform(prng, weights_IH, INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE);
		dim3 ihblocks((INPUT_LAYER_SIZE * HIDDEN_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::normalize << <ihblocks, blockSize >> > (weights_IH, INPUT_LAYER_SIZE, HIDDEN_LAYER_SIZE);

		curandGenerateUniform(prng, weights_HO, HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE);
		dim3 hoblocks((HIDDEN_LAYER_SIZE * OUTPUT_LAYER_SIZE + blockSize - 1) / blockSize);
		Functions::normalize << <hoblocks, blockSize >> > (weights_HO, HIDDEN_LAYER_SIZE, OUTPUT_LAYER_SIZE);
	}

	/*
	Clears all model matrices, buffers and destroys the handles
	*/
	void free() {
		cudaFree(weights_IH);
		cudaFree(weights_HO);
		cudaFree(g_weights_IH);
		cudaFree(g_weights_HO);
		cudaFree(hidden);
		cudaFree(h_sigmoid);
		cudaFree(output);
		cudaFree(o_softmax);
		cublasDestroy(cublas_handle);
	}
}
