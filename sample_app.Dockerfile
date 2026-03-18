# Sample Dockerfile for a Node.js Fullstack App
# Used for build-and-push steps in the CI/CD pipeline.

# Use a specific version for stability
FROM node:18-alpine

# Create app directory
WORKDIR /usr/src/app

# Install app dependencies
# A wildcard is used to ensure both package.json AND package-lock.json are copied
COPY package*.json ./

RUN npm install --only=production

# Bundle app source
COPY . .

# Expose the application port
EXPOSE 8080

# The startup command
CMD [ "node", "server.js" ]
