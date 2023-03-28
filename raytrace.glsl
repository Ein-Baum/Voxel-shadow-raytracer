#version 440
layout( local_size_x = 1, local_size_y = 1, local_size_z = 1) in; // There is just one worker for each pixel
layout(rgba32f, binding = 0) uniform image2D img_output;  // The output image, that also holds the raw color information of the voxels
layout(rgba32f, binding = 1) uniform image2D pos_texture;  // The image containing the position data (world space)
layout(rgba32f, binding = 4) uniform image2D norm_texture;  // The image containing the normals of the voxels

struct lightsource  // Holds information about the lightsource
{
	vec3 position;
	float power;   // Basically the distance that the light of a lightsource can reach
	vec3 color;
	float intensity;
};

struct voxel_material // The material a voxel is made of
{
	vec3 color;  // This property is not used at all, but could be used in the future
	float density; // Controls how much light can travel through this voxel. 1 if no light can travel through it and it is solid, 0 if it is made out of air.
};

layout (std430, binding = 2) buffer Lights // a buffer containing all lightsources
{
	lightsource sources[];
};

layout (std430, binding = 3) buffer Map // a buffer containing all voxels of the rendered voxel world. The coordinates start at 0,0,0. This can be tweaked by changing the hashing function CordToID
{
	voxel_material voxels[];
};

uniform vec3 cam_pos; // The position of the camera. This is not used currently, but it could be used to generate fog or something
uniform vec3 map_size; // The size of the voxel map

int CordtoID(vec3 cord){ // Converts 3D coordinates into a id that can be used to get voxels from the "Map" buffer above. Can be changed to fit your needs
	cord.x = max(0,min(map_size.x, cord.x));
	cord.y = max(0,min(map_size.y, cord.y));
	cord.z = max(0,min(map_size.z, cord.z));
	return int(floor(cord.x) + floor(cord.y) * map_size.x + floor(cord.z) * map_size.x * map_size.y);
}

float stepThroughVoxelWorld(vec3 origin, vec3 dir, bool stepThroughFirstVoxel); // The function for the DDA algorithm
float stepThroughVoxelWorldS(vec3 origin, vec3 dir, bool stepThroughFirstVoxel); // A very slow traversion algorithm that uses no smart math and just loops in small increments until it finds a voxel to collide with.

void main(){
	
	uint x = gl_GlobalInvocationID.x; // Get the current pixel coordinates
	uint y = gl_GlobalInvocationID.y;
	
	vec4 pixel = imageLoad(img_output, ivec2(x,y));            // Get the base color of the pixel
	vec4 position = imageLoad(pos_texture, ivec2(x,y));        // Get the position of the voxel from this pixel in world space
	vec3 normal = imageLoad(norm_texture, ivec2(x,y)).rgb;     // Get the normal of the voxel from this pixel
	
	if(position.a > 0){ // This is to save performance, as not all pixels have to be filled with data that has to be raytraced. The background for example
	
		vec4 lightValue = vec4(0.2,0.2,0.2,1); // 0.2 is the ambient lighting and therefor the minimum light every pixel will recieve
		
		int castLights = 0;             // Later, the number of lights that shine onto this pixel
		vec3 lightColor = vec3(0,0,0);  // The combined color of all lights shining on this pixel
		
		for(int i = 0; i < sources.length(); i++){  // Loop through all lights in the buffer
			
			lightsource current = sources[i];
			
			float distanceSP = distance(current.position, position.xyz);
			
			if(distanceSP <= current.power * current.power){    // Test if the lights power is enough to reach this pixel at all.
				
				vec3 rayPixSrc = vec3(current.position - position.xyz);    // A ray direction from the pixel to the light source
				
				float intensity = stepThroughVoxelWorld(vec3(position.xyz), rayPixSrc, dot(normalize(rayPixSrc), normal) > 0); // Call to the DDA algorithm. The dot product is to tell the function to
				                                                                                                               // also take the voxel into account that this pixel is from, because the
                                                                                                                       // light ray will go through it, and the voxel may will block the light
                                                                                                                       
				float result = current.intensity * intensity.x * (1 - (distanceSP / current.power));    // Compute the resulting multiplier of the lights 
                                                                                                // color depending on the distance of the light to the pixel
				
				if(result > 0){ // If there will be light shining on the pixel...
					
					castLights++;
					lightColor += current.color.rgb * result; // ...add it to the total light color
					
				}
        
			}
			
		}
		
		if(castLights > 0){ // If there were some lights that reached this pixel, add the combined light color to the total light color.
			lightValue.rgb += lightColor;
		}
		
		imageStore(img_output, ivec2(x,y), pixel * lightValue); // Multiply the raw base color with the combined light color and save it to the texture.
		
	}
}

float stepThroughVoxelWorldS(vec3 origin, vec3 dir, bool stepThroughFirstVoxel){ // The slow algorithm

	float intensity = 1;
	vec3 normDir = normalize(dir) * 0.05;
	float sLength = 0;
	vec3 currentPosition = vec3(origin);
	
	while(intensity > 0 && sLength < length(dir)){
		currentPosition += normDir;
		sLength += length(normDir);
	
		voxel_material currentVoxel = voxels[CordtoID(vec3(currentPosition.xyz))];
		
		intensity -= currentVoxel.density;
		
	}
	
	return intensity;
}

float stepThroughVoxelWorld(vec3 origin, vec3 dir, bool stepThroughFirstVoxel){ // The fast algorithm
	
	float intensity = 1;
	
  // Setup all important variables
	vec3 Max = vec3(0,0,0);
	ivec3 step = ivec3(0,0,0);
	vec3 delta = vec3(0,0,0);
	ivec3 Out = ivec3(0,0,0);

  // limiting values that ensure that the ray wont be traced forever
	vec3 last = vec3(floor(origin.x + dir.x), floor(origin.y + dir.y), floor(origin.z + dir.z));
	float maxLength = dir.x * dir.x + dir.y * dir.y + dir.z * dir.z;
	
  // Normalize the ray for simplicity
	dir = normalize(dir);
	
	ivec3 currPos = ivec3(floor(origin.x), floor(origin.y), floor(origin.z));
	
  // Configure the DDA algorithm (it is called the "initialisation phase" in the paper "http://www.cse.yorku.ca/~amana/research/grid.pdf"
	if(dir.x >= 0){
		
		float direct = max(0.000001, dir.x);
		step.x = 1;
		delta.x = 1 / direct;
		Max.x = (floor(currPos.x + 1) - origin.x) / direct;
		Out.x = int(map_size.x);
		
	}else{
		
		Max.x = (floor(currPos.x) - origin.x) / dir.x;
		step.x = -1;
		delta.x = -1 / dir.x;
		Out.x = -1;
		
	}
	
	
	if(dir.y >= 0){
		
		float direct = max(0.000001, dir.y);
		step.y = 1;
		delta.y = 1 / direct;
		Max.y = (floor(currPos.y + 1) - origin.y) / direct;
		Out.y = int(map_size.y);
		
	}else{
		
		
		Max.y = (floor(currPos.y) - origin.y) / dir.y;
		step.y = -1;
		delta.y = -1 / dir.y;
		Out.y = -1;
		
	}
	
	
	if(dir.z >= 0){
		
		float direct = max(0.000001, dir.z);
		step.z = 1;
		delta.z = 1 / direct;
		Max.z = (floor(currPos.z + 1) - origin.z) / direct;
		Out.z = int(map_size.z);
		
	}else{
		
		
		Max.z = (floor(currPos.z) - origin.z) / dir.z;
		step.z = -1;
		delta.z = -1 / dir.z;
		Out.z = -1;
		
	}
	
  // just for debugging
	int iterations = 0;
	
	bool reachedEnd = false;
	
  // Step thoug the voxel world until the intensity of the light is less or equal to 0, or the voxel where the lightsource is in is reached
	while(intensity > 0 && !reachedEnd && !(currPos.x == last.x && currPos.y == last.y && currPos.z == last.z)){
  
		iterations++;
		voxel_material currentVoxel = voxels[CordtoID(vec3(currPos.xyz))];
		intensity -= currentVoxel.density;
		
		if(Max.x < Max.y){
			
			if(Max.x < Max.z){
				
				currPos.x += step.x;
				if(currPos.x == Out.x){
					reachedEnd = true;
				}
				Max.x += delta.x;
				
			}else{
				
				currPos.z += step.z;
				if(currPos.z == Out.z){
					reachedEnd = true;
				}
				Max.z += delta.z;
				
			}
			
		}else{
			
			if(Max.y < Max.z){
				
				currPos.y += step.y;
				if(currPos.y == Out.y){
					reachedEnd = true;
				}
				Max.y += delta.y;
				
			}else{
				
				currPos.z += step.z;
				if(currPos.z == Out.z){
					reachedEnd = true;
				}
				Max.z += delta.z;
				
			}
			
		}
		
	}
	
	return intensity;
}
